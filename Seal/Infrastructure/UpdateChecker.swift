import Foundation

/// 启动更新通知检查器
/// 从 GitHub Releases 公共页面读取最新版本，有更新时弹窗提示
/// 弹窗标题和内容来自 Release 的 name 和 body，可在 GitHub 发版时自定义
struct UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "3188447354/MJorb-0.1.0"
    private let lastNotifiedVersionKey = "update_notifier.last_notified_version"
    private static let cache = UpdateCheckCache()

    /// 成功结果在本次进程内复用；新启动重新检查。手动重试只重试失败请求，
    /// 已是最新版或已有更新时不重复请求网络。
    func check(force: Bool = false) async -> UpdateCheckResult {
        let repository = repo
        let result = await Self.cache.result(force: force) {
            await Self.fetchLatest(repo: repository)
        }
        guard force == false else { return result }
        if case .available(let notice) = result {
            let lastNotified = UserDefaults.standard.string(forKey: lastNotifiedVersionKey)
            if lastNotified == notice.version { return .suppressed }
            UserDefaults.standard.set(notice.version, forKey: lastNotifiedVersionKey)
        }
        return result
    }

    private static func fetchLatest(repo: String) async -> UpdateCheckResult {
        guard let url = URL(string: "https://github.com/\(repo)/releases.atom") else {
            return .unavailable(.configuration)
        }

        do {
            let (data, http) = try await fetch(url, accept: "application/atom+xml")
            if let statusResult = Self.result(forHTTPStatus: http.statusCode) {
                return statusResult
            }

            guard let releases = Self.releaseEntries(
                from: data,
                repo: repo
            ) else {
                return .unavailable(.invalidRelease)
            }
            // The feed is newest publication first. Select that release before comparing
            // versions so an older historical tag with a numerically larger value cannot win.
            guard let release = releases.first else { return .latest }
            guard let versionComparison = Version.compareIfValid(release.tag, Version.current) else {
                return .unavailable(.invalidRelease)
            }
            if versionComparison != .orderedDescending {
                return .latest
            }

            let (ipaDownloadURL, sha256DownloadURL) = await Self.releaseAssetURLs(
                repo: repo,
                tag: release.tag
            )

            return .available(UpdateNotice(
                version: release.tag,
                title: release.title,
                message: release.message,
                downloadURL: release.pageURL,
                ipaDownloadURL: ipaDownloadURL,
                sha256DownloadURL: sha256DownloadURL
            ))
        } catch {
            return .unavailable(.network)
        }
    }

    private static func fetch(_ url: URL, accept: String = "text/html") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Seal", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    static func releaseEntries(
        from data: Data,
        repo: String
    ) -> [UpdateRelease]? {
        let delegate = UpdateReleaseFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawFeed else { return nil }

        return delegate.entries.compactMap { entry in
            guard let pageURL = URL(string: entry.pageURL),
                  isTrustedReleasePage(pageURL, repo: repo),
                  let tag = pageURL.pathComponents.last,
                  isAppleReleaseVersion(tag) else {
                return nil
            }
            return UpdateRelease(
                tag: tag,
                title: entry.title.isEmpty ? "发现新版本" : entry.title,
                message: plainText(fromHTML: entry.content),
                pageURL: pageURL
            )
        }
    }

    private static func isAppleReleaseVersion(_ version: String) -> Bool {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("v") || normalized.hasPrefix("V") {
            normalized.removeFirst()
        }
        let components = normalized.split(separator: ".")
        guard components.count == 3,
              components.allSatisfy({ component in
                  component.utf8.allSatisfy { (48...57).contains($0) }
              }) else { return false }
        return true
    }

    private static func isTrustedReleasePage(_ url: URL, repo: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else { return false }
        let components = url.pathComponents
        return components.count == 6
            && components[1...4].joined(separator: "/") == "\(repo)/releases/tag"
    }

    private static func plainText(fromHTML html: String) -> String {
        let withBreaks = html.replacingOccurrences(
            of: "(?i)</(li|p|div)>|<br\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        let withoutTags = withBreaks.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func releaseAssetURLs(repo: String, tag: String) async -> (URL?, URL?) {
        guard let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://github.com/\(repo)/releases/expanded_assets/\(encodedTag)") else {
            return (nil, nil)
        }
        do {
            let (data, response) = try await fetch(url)
            guard response.statusCode == 200,
                  let baseURL = response.url,
                  isTrustedDownloadURL(baseURL),
                  let html = String(data: data, encoding: .utf8) else {
                return (nil, nil)
            }
            let assets = releaseAssets(from: html, relativeTo: baseURL)
            guard let ipaURL = ipaDownloadURL(from: assets),
                  let checksumURL = sha256DownloadURL(from: assets) else {
                return (nil, nil)
            }
            return (ipaURL, checksumURL)
        } catch {
            return (nil, nil)
        }
    }

    static func releaseAssets(from html: String, relativeTo baseURL: URL) -> [[String: Any]] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*\bhref="([^"]+)"[^>]*>"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let hrefRange = Range(match.range(at: 1), in: html) else { return nil }
            let href = String(html[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  isTrustedDownloadURL(url) else { return nil }
            return ["name": url.lastPathComponent, "browser_download_url": url.absoluteString]
        }
    }

    // MARK: - 更新资产的真实性

    /// Release 声称的版本（`tag_name`）与 IPA 内真实版本是否一致。
    ///
    /// 这是一次**跨源交叉验证**：版本标签来自 GitHub Releases 的 Atom 元数据，
    /// `CFBundleShortVersionString` 来自**下载到的二进制本身**。
    /// 只校验下载域名是不够的 —— 同一仓库、同一合法域名下的资产仍然可以被替换，
    /// 那种情况下域名校验完全看不出异常。两边对不上，说明这个包要么不属于这个
    /// Release、要么内容被换过，装下去就是远程代码执行。
    ///
    /// 用 `Version.compare` 而不是字符串相等：tag 可能是 `v1.0.13`，
    /// IPA 内是 `1.0.13`，而 `Version` 已经处理了 `v` 前缀与多段版本号。
    static func advertisedVersion(_ advertised: String, matchesIPAVersion ipaVersion: String) -> Bool {
        Version.compareIfValid(advertised, ipaVersion) == .orderedSame
    }

    /// Release 资产的下载直链必须来自 GitHub 官方域名，且必须是 HTTPS。
    ///
    /// 下载链接来自 GitHub 附件页。仓库名虽然是硬编码的，但响应内容本身
    /// 是不可信输入：一旦它指向攻击者的域名，「应用内更新」就会变成远程代码投递通道。
    /// 因此这里独立校验 scheme 与 host，不信任响应里说什么就是什么。
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "github.com"
            || host == "objects.githubusercontent.com"
            || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    /// 确定性地挑出 IPA 直链。
    ///
    /// 旧实现取**第一个**后缀为 `.ipa` 的附件：一次 Release 挂了多个 IPA 时
    /// （不同架构、测试包、或后补的附件）装哪个全看页面链接顺序 ——
    /// 既不确定，也让「往 Release 里多加一个附件」成为可行的投毒手法。
    /// 现在改为：**恰好一个**才给直链；没有或多个都不给，
    /// 回退到 Release 详情页由用户在浏览器里自己选。
    static func ipaDownloadURL(from assets: [[String: Any]]) -> URL? {
        let candidates = assets.compactMap { attachment -> URL? in
            guard let name = attachment["name"] as? String,
                  name.lowercased().hasSuffix(".ipa"),
                  let raw = attachment["browser_download_url"] as? String,
                  let url = URL(string: raw),
                  isTrustedDownloadURL(url) else {
                return nil
            }
            return url
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    /// 与 `ipaDownloadURL` 对称：从 Release 资产里挑出唯一一个 `.sha256` 直链（同样过域名白名单）。
    /// 内容由发布脚本 `shasum -a 256 "$ipa" > "$ipa.sha256"` 生成。
    static func sha256DownloadURL(from assets: [[String: Any]]) -> URL? {
        let candidates = assets.compactMap { attachment -> URL? in
            guard let name = attachment["name"] as? String,
                  name.lowercased().hasSuffix(".sha256"),
                  let raw = attachment["browser_download_url"] as? String,
                  let url = URL(string: raw),
                  isTrustedDownloadURL(url) else {
                return nil
            }
            return url
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    /// `shasum` 输出第一个空白分隔 token 是 64 位小写十六进制 hash。
    /// 长度 / 字符集不对（内容被截断或投毒）一律返回 nil，由调用方 fail closed。
    static func expectedSHA256(from content: String) -> String? {
        let token = content
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
        guard let hash = token,
              hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return hash
    }

    /// 忽略大小写的 hash 比对（`shasum` 与 `FileHandle` 两端都可能混大小写）。
    static func hashMatches(expected: String, actual: String) -> Bool {
        expected.caseInsensitiveCompare(actual) == .orderedSame
    }

    static func failure(forHTTPStatus statusCode: Int) -> UpdateCheckFailure {
        switch statusCode {
        case 404: return .serviceUnavailable
        case 403, 429: return .rateLimited
        case 500...599: return .serviceUnavailable
        default: return .serviceUnavailable
        }
    }

    /// 404 from Releases/latest means this repository has no published latest release yet.
    /// 200 continues into version parsing; other statuses remain actionable failures.
    static func result(forHTTPStatus statusCode: Int) -> UpdateCheckResult? {
        switch statusCode {
        case 200: return nil
        case 404: return .latest
        default: return .unavailable(failure(forHTTPStatus: statusCode))
        }
    }
}

enum UpdateCheckResult: Sendable {
    case unavailable(UpdateCheckFailure)
    case latest
    case suppressed
    case available(UpdateNotice)
}

enum UpdateCheckFailure: Equatable, Sendable {
    case configuration
    case rateLimited
    case serviceUnavailable
    case invalidRelease
    case network

    var statusText: String {
        switch self {
        case .rateLimited: return "更新服务暂时限制了请求"
        case .serviceUnavailable: return "更新服务暂时不可用"
        case .invalidRelease: return "更新版本信息无效"
        case .configuration, .network: return "未能获取版本信息"
        }
    }

    var detail: String {
        switch self {
        case .rateLimited: return "请稍后重试，或更换网络后再检查"
        case .serviceUnavailable: return "请检查网络后重试"
        case .invalidRelease: return "请等待开发者修正发布信息后再试"
        case .configuration, .network: return "请检查网络后重试"
        }
    }
}

struct UpdateNotice: Identifiable, Sendable {
    let id = UUID()
    let version: String
    let title: String
    let message: String
    let downloadURL: URL?
    let ipaDownloadURL: URL?
    let sha256DownloadURL: URL?
}

enum UpdateNoticeContentPolicy {
    static func changeItems(from message: String, version: String) -> [String] {
        message.components(separatedBy: .newlines).compactMap { line in
            let isHeading = line.range(
                of: "^\\s*#{1,6}\\s+",
                options: .regularExpression
            ) != nil
            var text = line.trimmingCharacters(in: .whitespaces)
            text = text.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*[-*•·]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            guard isHeading == false || normalizedVersion(trimmed) != normalizedVersion(version) else {
                return nil
            }
            return trimmed
        }
    }

    private static func normalizedVersion(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("v") ? String(normalized.dropFirst()) : normalized
    }
}

struct UpdateRelease: Equatable, Sendable {
    let tag: String
    let title: String
    let message: String
    let pageURL: URL
}

private struct ParsedUpdateRelease {
    var pageURL = ""
    var title = ""
    var content = ""
}

private final class UpdateReleaseFeedParser: NSObject, XMLParserDelegate {
    private(set) var entries: [ParsedUpdateRelease] = []
    private(set) var sawFeed = false
    private var currentEntry: ParsedUpdateRelease?
    private var activeField: String?
    private var fieldText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = elementName.lowercased()
        if element == "feed" { sawFeed = true }
        if element == "entry" {
            currentEntry = ParsedUpdateRelease()
            return
        }
        guard currentEntry != nil else { return }
        if element == "link", attributeDict["rel"] == "alternate",
           let href = attributeDict["href"] {
            currentEntry?.pageURL = href
        } else if element == "title" || element == "content" {
            activeField = element
            fieldText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard activeField != nil else { return }
        fieldText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        if element == activeField {
            if element == "title" { currentEntry?.title = fieldText }
            if element == "content" { currentEntry?.content = fieldText }
            activeField = nil
            fieldText = ""
        }
        if element == "entry", let currentEntry {
            entries.append(currentEntry)
            self.currentEntry = nil
        }
    }
}

actor UpdateCheckCache {
    private var cachedResult: UpdateCheckResult?
    private var inFlight: Task<UpdateCheckResult, Never>?

    func result(
        force: Bool,
        load: @escaping @Sendable () async -> UpdateCheckResult
    ) async -> UpdateCheckResult {
        if let cachedResult {
            if case .unavailable = cachedResult {
                if force == false { return cachedResult }
                self.cachedResult = nil
            } else {
                return cachedResult
            }
        }

        let result: UpdateCheckResult
        if let inFlight {
            result = await inFlight.value
        } else {
            let task = Task { await load() }
            inFlight = task
            result = await task.value
            cachedResult = result
            inFlight = nil
        }
        return result
    }
}
