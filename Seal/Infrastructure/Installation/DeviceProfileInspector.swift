//
//  DeviceProfileInspector.swift
//  Seal
//
//  只读枚举设备端描述文件引用的证书序列号，供「清理不可用证书」判定
//  「这张证书是否还有 App 在设备上靠它运行」。与 DeviceProfileCleaner 共用
//  misagent dump 通道，但绝不删除任何文件。
//

import Foundation
@preconcurrency import Minimuxer

struct DeviceProfileInspector: Sendable {
    /// Read-only `misagent` warmup. A successful UDID/RSD check does not prove the
    /// profile service is ready; doing this while Apple Portal prepares profiles
    /// overlaps device setup with network work instead of paying for it at injection.
    static func prewarmMisagentService(
        using operationCoordinator: OperationCoordinator? = nil,
        onNativeCompletion: @escaping @Sendable () async -> Void = {}
    ) async -> DeviceProfileNativeCall.Outcome<Void> {
        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-profile-prewarm-\(UUID().uuidString)", isDirectory: true)
        return await DeviceProfileNativeCall.perform(
            operationCoordinator: operationCoordinator,
            seconds: 8,
            waitForAvailability: false,
            onNativeCompletion: onNativeCompletion
        ) {
            defer { try? FileManager.default.removeItem(at: workingDir) }
            let dumpDir = try Provision.dumpProfiles(docsPath: workingDir.path)
            // An empty profile directory is still a healthy service response.
            _ = try FileManager.default.contentsOfDirectory(atPath: dumpDir)
        }
    }

    /// 批量核验：一次 dump + 全量 CMS 解析，核验全部 bindings。
    /// 按输入顺序返回每个 binding 的核验结果（`nil` = dump 不可用，`false` = 枚举成功但未找到）。
    /// 供 `installAndVerify` 一次注入全部后统一核验，避免每份 profile 各做一次秒级 dump。
    static func containsProfiles(
        matching bindings: [ProvisioningProfileBinding],
        certificateSerialNumber: String,
        using operationCoordinator: OperationCoordinator? = nil,
        onNativeCompletion: @escaping @Sendable () async -> Void = {}
    ) async -> DeviceProfileNativeCall.Outcome<[Bool?]> {
        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-profile-verify-\(UUID().uuidString)", isDirectory: true)
        return await DeviceProfileNativeCall.perform(
            operationCoordinator: operationCoordinator,
            seconds: 30,
            waitForAvailability: true,
            onNativeCompletion: onNativeCompletion
        ) {
            defer { try? FileManager.default.removeItem(at: workingDir) }

            guard let dumpDir = try? Provision.dumpProfiles(docsPath: workingDir.path),
                  let profileURLs = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: dumpDir),
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else { return bindings.map { _ in nil } }

            let expectedSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificateSerialNumber)
            let reader = ProvisioningProfileReader()
            // 一次解析全部，建 (bundleID.lowercased, uuid.lowercased) -> (creation, expiration, serials) 索引
            var index: [String: (creation: Date?, expiration: Date?, serials: [String])] = [:]
            var parsed = 0
            var handledUUIDs = Set<String>()
            for fileURL in profileURLs {
                guard let data = try? Data(contentsOf: fileURL),
                      let details = try? reader.details(from: data) else { continue }
                if let uuid = details.uuid, handledUUIDs.insert(uuid).inserted == false { continue }
                parsed += 1
                guard let bid = details.bundleIdentifier?.lowercased(),
                      let uuid = details.uuid?.lowercased() else { continue }
                index["\(bid)|\(uuid)"] = (details.creationDate, details.expirationDate, details.certificateSerialNumbers)
            }
            guard parsed > 0 else { return bindings.map { _ in nil } }

            return bindings.map { binding in
                guard let profileUUID = binding.profileUUID, profileUUID.isEmpty == false,
                      let entry = index["\(binding.bundleIdentifier.lowercased())|\(profileUUID.lowercased())"] else {
                    return false
                }
                guard entry.creation == binding.creationDate,
                      entry.expiration == binding.expirationDate,
                      entry.serials.contains(where: {
                          SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == expectedSerial
                      }) else { return false }
                return true
            }
        }
    }

    /// 设备端全部描述文件引用的证书序列号集合（已归一化，见 DEBUG_LOG 坑位 1）。
    ///
    /// 返回 `nil` 表示**无法核验**（未连接设备/隧道不可用/dump 或解析失败），
    /// 调用方必须按「未核验」降级处理，绝不能当成「设备上没有引用」。
    /// 返回空集仅当设备端确实一份描述文件都没有。
    static func referencedCertificateSerials(
        using operationCoordinator: OperationCoordinator? = nil,
        waitForAvailability: Bool = false
    ) async -> Set<String>? {
        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-profile-inspect-\(UUID().uuidString)", isDirectory: true)
        let outcome = await DeviceProfileNativeCall.perform(
            operationCoordinator: operationCoordinator,
            seconds: BlockingCall.queryTimeoutSeconds,
            waitForAvailability: waitForAvailability
        ) {
            return try Self.readReferencedCertificateSerials(in: workingDir)
        }
        guard case .completed(let result) = outcome else { return nil }
        do { return try result.get() } catch { return nil }
    }

    private static func readReferencedCertificateSerials(in workingDir: URL) throws -> Set<String>? {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: workingDir) }
        let dumpDir = try Provision.dumpProfiles(docsPath: workingDir.path)
        let dumpURL = URL(fileURLWithPath: dumpDir)
        guard let profileURLs = try? fileManager.contentsOfDirectory(
            at: dumpURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        // 设备端确实没有描述文件：空集是有效结论（没有任何证书被引用）。
        if profileURLs.isEmpty { return [] }

        let reader = ProvisioningProfileReader()
        var serials = Set<String>()
        var parsed = 0
        var handledUUIDs = Set<String>()
        for fileURL in profileURLs {
            // 与 DeviceProfileCleaner 同约定：不按扩展名过滤，misagent 返回的是 CMS
            // 包裹的二进制，识别一律交给 ProvisioningProfileReader 解 CMS。
            guard let data = try? Data(contentsOf: fileURL),
                  let details = try? reader.details(from: data) else { continue }
            // LockDown 路径同一 profile 会落 raw + plist 两份，按 UUID 去重
            if let uuid = details.uuid, handledUUIDs.insert(uuid).inserted == false { continue }
            parsed += 1
            for serial in details.certificateSerialNumbers {
                serials.insert(SigningCertificateSelectionPolicy.normalizedSerialNumber(serial))
            }
        }
        // 目录里有文件却一份都解析不出来 = 核验失败，不是「没有引用」。
        return parsed > 0 ? serials : nil
    }
}
