import Foundation
import MachO

/// 启动时发现的未知动态代码，只提示、不拦截功能。
///
/// Apple ID 重签会改变 Team ID 和 Seal 当前使用的 Bundle ID 后缀；这些身份字段不能证明代码被改。
/// 只有加载到 Apple 系统目录、Seal 主程序和已知 OpenSSL 之外的动态代码才作为注入线索。
enum AppIntegrityIssue: Equatable {
    case unexpectedDynamicLibrary(String)

    /// 稳定标识只保留库名，不包含每次安装都会变化的容器路径。
    var warningIdentifier: String {
        switch self {
        case .unexpectedDynamicLibrary(let path):
            return "unexpected-library-\(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }

    var componentName: String {
        switch self {
        case .unexpectedDynamicLibrary(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    var imagePath: String {
        switch self {
        case .unexpectedDynamicLibrary(let path): path
        }
    }
}

/// 启动时枚举已加载代码。合法的个人重签和不同 Team ID 不会触发提醒。
enum AppIntegrityCheck {
    static func findings(
        loadedImagePaths: [String],
        executablePath: String?,
        expectedEmbeddedDynamicLibraryPaths: Set<String> = []
    ) -> [AppIntegrityIssue] {
        let normalizedExecutablePath = executablePath.map(normalizedFilePath)
        let normalizedEmbeddedPaths = Set(expectedEmbeddedDynamicLibraryPaths.map(normalizedFilePath))
        return loadedImagePaths.compactMap { path in
            let normalizedPath = normalizedFilePath(path)
            if normalizedPath == normalizedExecutablePath,
               normalizedExecutablePath != nil {
                return nil
            }
            if normalizedEmbeddedPaths.contains(normalizedPath) {
                return nil
            }
            // Keep recognizing Apple's sealed system roots even if their spelling resolves through a symlink.
            if isSystemImagePath(path) || isSystemImagePath(normalizedPath) {
                return nil
            }
            return .unexpectedDynamicLibrary(path)
        }
    }

    private static func normalizedFilePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    /// 从真实环境读取并判一次。只在启动时枚举已加载镜像。
    static func liveFindings() -> [AppIntegrityIssue] {
        let bundle = Bundle.main
        var imagePaths: [String] = []
        let imageCount = _dyld_image_count()
        for index in 0..<imageCount {
            if let name = _dyld_get_image_name(index) {
                imagePaths.append(String(cString: name))
            }
        }
        return findings(
            loadedImagePaths: imagePaths,
            executablePath: bundle.executablePath,
            expectedEmbeddedDynamicLibraryPaths: trustedEmbeddedDynamicLibraryPaths(in: bundle)
        )
    }

    /// iOS system libraries can be reported from the normal roots or from the OS
    /// cryptex mount. The simulator reports its host-mounted runtime under RuntimeRoot.
    /// Use path-component boundaries so similarly prefixed third-party paths do not pass.
    private static func isSystemImagePath(_ path: String) -> Bool {
        let systemRoots = [
            "/System",
            "/usr/lib",
            "/private/preboot/Cryptexes/OS/System",
            "/private/preboot/Cryptexes/OS/usr/lib",
        ]
        if systemRoots.contains(where: { isPath(path, inside: $0) }) {
            return true
        }
        #if targetEnvironment(simulator)
        guard path.hasPrefix("/Library/Developer/CoreSimulator/Volumes/"),
              let runtimeRoot = path.range(of: "/RuntimeRoot/") else {
            return false
        }
        let runtimePath = path[runtimeRoot.upperBound...]
        return runtimePath == "System"
            || runtimePath.hasPrefix("System/")
            || runtimePath == "usr/lib"
            || runtimePath.hasPrefix("usr/lib/")
        #else
        return false
        #endif
    }

    private static func isPath(_ path: String, inside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// Seal 当前唯一的嵌入式动态依赖。只信任 Frameworks 目录下 Bundle ID 匹配的 OpenSSL；
    /// 其他随包加载的动态库仍会触发提醒。
    private static func trustedEmbeddedDynamicLibraryPaths(in bundle: Bundle) -> Set<String> {
        let expectedBundleIdentifiers: Set<String> = ["com.github.krzyzanowskim.OpenSSL"]
        let frameworksURL = bundle.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: frameworksURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(urls.compactMap { url in
            guard let framework = Bundle(url: url),
                  let identifier = framework.bundleIdentifier,
                  expectedBundleIdentifiers.contains(identifier),
                  let executableURL = framework.executableURL else {
                return nil
            }
            return normalizedFilePath(executableURL.path)
        })
    }
}
