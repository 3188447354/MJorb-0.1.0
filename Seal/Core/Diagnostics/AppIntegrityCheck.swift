import Foundation
import MachO

/// 启动自检发现的改动痕迹。只用于弹警告，不锁死、不拦截功能。
///
/// 约束（2026-10-24 防篡改设计定稿）：
/// - 不能按签名者认官方：每个用户重签后的签名者本来就不同，只能认“被改过的痕迹”。
/// - 越狱设备上注入基本防不住，这里只做到“露馅”，不承诺拦住。
/// - 误报纪律：下面每个判据的合法锚点都必须是正常构建必然成立的事实
///   （固定 Bundle ID、Info.plist 必备键、Assets.car、静态链接的 RustBridge），
///   否则宁可不查，不给正常用户弹假警告。
enum AppIntegrityIssue: Equatable {
    /// Bundle ID 与工程固定值不一致（被改包换 ID）。
    case bundleIdentifierChanged
    /// 主包内必然存在的文件缺失。
    case requiredResourceMissing(String)
    /// Info.plist 缺键、字段为空、可执行名对不上、或与内置原始 Bundle ID 对不上。
    case infoPlistInvalid
    /// 加载了系统与主程序之外的动态库（注入、重打包时捆入的第三方 dylib）。
    case unexpectedDynamicLibrary(String)
    /// 调试器挂接。
    case debuggerAttached
}

/// 启动时轻量自检（防篡改第三层，2026-10-25）。
///
/// 判据函数 `findings` 是纯函数：全部输入外置，可单测，不读 Bundle、不碰 dyld、不调 sysctl；
/// `liveFindings` 只是把真实环境读出来喂给它。
enum AppIntegrityCheck {
    /// 工程固定值（project.yml 主 target 的 PRODUCT_BUNDLE_IDENTIFIER）。
    static let expectedBundleIdentifier = "com.mjorb.seal"

    /// 主包内必然存在的文件：Info.plist 与编译后的资源目录。
    static let requiredResourceNames = ["Info.plist", "Assets.car"]

    static func findings(
        bundleIdentifier: String?,
        executableFileName: String?,
        infoDictionary: [String: Any]?,
        presentResourceNames: Set<String>,
        loadedImagePaths: [String],
        executablePath: String?,
        debuggerAttached: Bool
    ) -> [AppIntegrityIssue] {
        var issues: [AppIntegrityIssue] = []

        if bundleIdentifier != expectedBundleIdentifier {
            issues.append(.bundleIdentifierChanged)
        }

        if let info = infoDictionary {
            let requiredKeys = [
                "CFBundleIdentifier",
                "CFBundleShortVersionString",
                "CFBundleVersion",
                "CFBundleExecutable",
                "SealOriginalBundleIdentifier",
            ]
            var infoOK = true
            for key in requiredKeys {
                guard let value = info[key] as? String, !value.isEmpty else {
                    infoOK = false
                    break
                }
            }
            if infoOK {
                if let executableInPlist = info["CFBundleExecutable"] as? String,
                   executableInPlist != executableFileName {
                    infoOK = false
                }
                if let originalID = info["SealOriginalBundleIdentifier"] as? String,
                   originalID != bundleIdentifier {
                    infoOK = false
                }
            }
            if !infoOK {
                issues.append(.infoPlistInvalid)
            }
        } else {
            issues.append(.infoPlistInvalid)
        }

        for name in requiredResourceNames where !presentResourceNames.contains(name) {
            issues.append(.requiredResourceMissing(name))
        }

        for path in loadedImagePaths {
            if path == executablePath { continue }
            // 系统库与主程序之外的一切动态库都算痕迹：RustBridge 是静态链接，
            // 正常构建的主进程不加载任何第三方 Framework，越狱注入与重打包捆入都落在这里。
            if path.hasPrefix("/System/") || path.hasPrefix("/usr/lib") { continue }
            issues.append(.unexpectedDynamicLibrary(path))
        }

        if debuggerAttached {
            issues.append(.debuggerAttached)
        }

        return issues
    }

    /// 从真实环境读取并判一次。只在启动时跑一次，代价是枚举已加载镜像与几次文件存在性检查。
    static func liveFindings() -> [AppIntegrityIssue] {
        let bundle = Bundle.main
        var present: Set<String> = []
        let fileManager = FileManager.default
        for name in requiredResourceNames {
            if fileManager.fileExists(atPath: bundle.bundlePath + "/" + name) {
                present.insert(name)
            }
        }
        var imagePaths: [String] = []
        let imageCount = _dyld_image_count()
        for index in 0..<imageCount {
            if let name = _dyld_get_image_name(index) {
                imagePaths.append(String(cString: name))
            }
        }
        return findings(
            bundleIdentifier: bundle.bundleIdentifier,
            executableFileName: bundle.executableURL?.lastPathComponent,
            infoDictionary: bundle.infoDictionary,
            presentResourceNames: present,
            loadedImagePaths: imagePaths,
            executablePath: bundle.executablePath,
            debuggerAttached: isDebuggerAttached()
        )
    }

    /// sysctl 查 P_TRACED：调试器挂接即为真。失败（取不到进程信息）按“无调试器”计，
    /// 不因一次探测失败就弹警告。
    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var infoSize = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = mib.withUnsafeMutableBufferPointer { mibPointer in
            sysctl(mibPointer.baseAddress, 4, &info, &infoSize, nil, 0)
        }
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
