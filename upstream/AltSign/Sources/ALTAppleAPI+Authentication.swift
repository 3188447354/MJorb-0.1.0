//
//  ALTAppleAPI+Authentication.swift
//  AltSign
//
//  Created by Riley Testut on 8/15/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import SwiftBridge

// GrandSlam is an AuthKit flow, distinct from the later Developer Portal
// session. Keep its fingerprint aligned with the Android ADI data generated
// locally and with the 2FA requests below.
// SideInstaller 1.5.1（isideload `grandslam.rs` 的 `base_headers`）用的就是
// 27.0 (27A5218g)，与 `X-Mme-Client-Info` 里的 macOS 27.0 同源。此前的
// 14.2 (14C18) 是 AltSign 上游的 2022 年旧值，与身份串里的系统版本不一致。
private let grandSlamAuthenticationXcodeVersion = "27.0 (27A5218g)"
private let grandSlamAuthenticationAppInfo = "com.apple.gs.xcode.auth"

/// Per-login state. Apple's new `hsc = 409` response means it has already
/// delivered a trusted-device code. Retrying that branch after a successful
/// validation would otherwise display the same prompt forever.
private final class ALTAuthenticationAttemptContext {
    var handledPushedCode = false
}

public extension ALTAppleAPI
{
    @objc func authenticate(appleID unsanitizedAppleID: String,
                            password: String,
                            anisetteData: ALTAnisetteData,
                            xcodeVersion: String,
                            verificationHandler: ((@escaping (String?) -> Void) -> Void)?,
                            completionHandler: @escaping (ALTAccount?, ALTAppleAPISession?, Error?) -> Void) {
        authenticate(appleID: unsanitizedAppleID,
                     password: password,
                     anisetteData: anisetteData,
                     xcodeVersion: xcodeVersion,
                     attemptContext: ALTAuthenticationAttemptContext(),
                     verificationHandler: verificationHandler,
                     completionHandler: completionHandler)
    }

    private func authenticate(appleID unsanitizedAppleID: String,
                              password: String,
                              anisetteData: ALTAnisetteData,
                              xcodeVersion: String,
                              attemptContext: ALTAuthenticationAttemptContext,
                              verificationHandler: ((@escaping (String?) -> Void) -> Void)?,
                              completionHandler: @escaping (ALTAccount?, ALTAppleAPISession?, Error?) -> Void) {
        // Authenticating only works with lowercase email address, even if Apple ID contains capital letters.
        let sanitizedAppleID = unsanitizedAppleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        debugLog("[AltSign] Starting authenticate for Apple ID: \(sanitizedAppleID)")

        do {
            // cpd（client provided data）是 Apple 判定客户端一致性的字典。
            // 与 SideInstaller 的 isideload `get_client_provided_data()` 逐字段对齐：
            // ① 布尔值用**字符串** `"true"`/`"false"`（plist 写成 <string> 而非 <true/>）；
            // ② `loc` 固定 `en_US`，不取设备 locale（中文机的 zh_CN 会与身份串里的
            //    en_US 不一致）；
            // ③ isideload 的 `get_headers()` 把 X-Apple-Locale / MD-LU / MD-RINFO /
            //    SRL-NO / Client-Time / TimeZone **全部注释掉不发**（试过被拒的痕迹），
            //    这里同样不发 —— 尤其 `X-Apple-I-SRL-NO: "0"` 是假序列号。
            let clientDictionary = [
                "bootstrap": "true",
                "icscrec": "true",
                "pbe": "false",
                "prkgen": "true",
                "svct": "iCloud",
                "loc": "en_US",
                "X-Apple-I-MD": anisetteData.oneTimePassword,
                "X-Apple-I-MD-M": anisetteData.machineID,
                "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier
            ] as [String: Any]

            let context = GSAContext(username: sanitizedAppleID, password: password)
            guard let publicKey = context.start() else {
                verboseLog("[AltSign] Failed to start GSAContext / generate public key A")
                throw ALTAppleAPIError.authenticationHandshakeFailed
            }

            verboseLog("[AltSign] GSAContext started. Generated public key A (A2k): \(publicKey.hexEncodedString())")

            let parameters = [
                "A2k": publicKey,
                "cpd": clientDictionary,
                "ps": ["s2k", "s2k_fo"],
                "o": "init",
                "u": sanitizedAppleID
            ] as [String: Any]

            debugLog("[AltSign] Sending authentication 'init' request...")
            sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { result in
                do {
                    let responseDictionary = try result.get()

                    guard let c = responseDictionary["c"] as? String,
                          let salt = responseDictionary["s"] as? Data,
                          let iterations = responseDictionary["i"] as? Int,
                          let serverPublicKey = responseDictionary["B"] as? Data
                    else {
                        verboseLog("[AltSign] Failed to parse authentication init response dictionary: \(responseDictionary)")
                        throw ALTServerError.badServerResponse(reason: "Auth init response missing c/s/i/B parameters", jsonPayload: self.formatPayloadJSON(responseDictionary))
                    }

                    verboseLog("""
                    [AltSign] Received init response:
                      • c: \(c)
                      • salt: \(salt.hexEncodedString())
                      • iterations: \(iterations)
                      • B: \(serverPublicKey.hexEncodedString())
                    """)

                    context.salt = salt
                    context.serverPublicKey = serverPublicKey

                    let sp = responseDictionary["sp"] as? String
                    let isHexadecimal = (sp == "s2k_fo")

                    guard let verificationMessage = context.makeVerificationMessage(iterations: iterations, isHexadecimal: isHexadecimal) else {
                        verboseLog("[AltSign] Failed to generate verification message M1")
                        throw ALTAppleAPIError.authenticationHandshakeFailed
                    }

                    verboseLog("[AltSign] Generated verification message M1: \(verificationMessage.hexEncodedString())")

                    let parameters = [
                        "c": c,
                        "cpd": clientDictionary,
                        "M1": verificationMessage,
                        "o": "complete",
                        "u": sanitizedAppleID
                    ] as [String: Any]

                    debugLog("[AltSign] Sending authentication 'complete' request...")
                    self.sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { result in
                        do {
                            let responseDictionary = try result.get()

                            guard let serverVerificationMessage = responseDictionary["M2"] as? Data,
                                  let serverDictionary = responseDictionary["spd"] as? Data,
                                  let statusDictionary = responseDictionary["Status"] as? [String: Any]
                            else {
                                verboseLog("[AltSign] Failed to parse complete response dictionary: \(responseDictionary)")
                                throw ALTServerError.badServerResponse(reason: "Auth complete response missing M2/spd/Status parameters", jsonPayload: self.formatPayloadJSON(responseDictionary))
                            }

                            verboseLog("""
                            [AltSign] Received complete response:
                              • M2: \(serverVerificationMessage.hexEncodedString())
                              • spd size: \(serverDictionary.count) bytes
                            """)

                            guard context.verifyServerVerificationMessage(serverVerificationMessage) else {
                                verboseLog("[AltSign] Server verification message M2 failed validation!")
                                throw ALTAppleAPIError.authenticationHandshakeFailed
                            }
                            verboseLog("[AltSign] Server verification message M2 validated successfully.")

                            guard let decryptedData = serverDictionary.decryptedCBC(context: context) else {
                                verboseLog("[AltSign] Failed to decrypt server dictionary (spd)")
                                throw ALTAppleAPIError.authenticationHandshakeFailed
                            }
                            verboseLog("[AltSign] Decrypted server dictionary successfully.")

                            guard let decryptedDictionary = self.parsePlistOrJSON(decryptedData) else {
                                let rawDecrypted = self.formatPayloadJSON(decryptedData)
                                verboseLog("[AltSign] Decrypted payload format is invalid (neither Plist nor JSON): \(rawDecrypted)")
                                throw ALTServerError.invalidResponseFormat(rawPayload: rawDecrypted)
                            }

                            guard let dsid = (decryptedDictionary["adsid"] as? String) ?? (decryptedDictionary["dsid"] as? CustomStringConvertible)?.description,
                                  let idmsToken = (decryptedDictionary["GsIdmsToken"] as? String) ?? (decryptedDictionary["idmsToken"] as? String)
                            else {
                                let jsonStr = self.formatPayloadJSON(decryptedDictionary)
                                verboseLog("[AltSign] Decrypted dictionary missing adsid/GsIdmsToken: \(jsonStr)")
                                throw ALTServerError.missingKey(key: "adsid/GsIdmsToken", jsonPayload: jsonStr)
                            }

                            verboseLog("[AltSign] Parse complete. dsid: \(dsid), token: \(idmsToken)")
                            context.dsid = dsid

                            // Apple can now omit `au` and return hsc=409 after
                            // it has already pushed a code to the trusted device.
                            // Treat that response as 2FA instead of attempting
                            // apptokens, which leaves the UI with no code field.
                            let highSecurityCode = (statusDictionary["hsc"] as? NSNumber)?.intValue
                                ?? (statusDictionary["hsc"] as? String).flatMap(Int.init)
                            let authType = (statusDictionary["au"] as? String)
                                ?? (responseDictionary["au"] as? String)
                                ?? (highSecurityCode == 409 ? "pushedCode" : nil)
                            verboseLog("[AltSign] Authentication status type: \(authType ?? "nil")")

                            switch authType {
                            case "trustedDeviceSecondaryAuth", "trustedDevice", "pushedCode":
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }
                                let pushedCode = authType == "pushedCode"
                                guard !pushedCode || !attemptContext.handledPushedCode else {
                                    throw ALTAppleAPIError.requiresTwoFactorAuthentication
                                }

                                self.requestTrustedDeviceTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, isCodeAlreadySent: pushedCode, verificationHandler: verificationHandler) { result in
                                    switch result {
                                    case let .failure(error): completionHandler(nil, nil, error)
                                    case .success:
                                        attemptContext.handledPushedCode = attemptContext.handledPushedCode || pushedCode
                                        self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: anisetteData, xcodeVersion: xcodeVersion, attemptContext: attemptContext, verificationHandler: verificationHandler, completionHandler: completionHandler)
                                    }
                                }

                            case "secondaryAuth", "sms", "voice", "phone":
                                guard let verificationHandler = verificationHandler else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                                self.requestSMSTwoFactorCode(dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData, verificationHandler: verificationHandler) { result in
                                    switch result {
                                    case let .failure(error): completionHandler(nil, nil, error)
                                    case .success:
                                        self.authenticate(appleID: unsanitizedAppleID, password: password, anisetteData: anisetteData, xcodeVersion: xcodeVersion, attemptContext: attemptContext, verificationHandler: verificationHandler, completionHandler: completionHandler)
                                    }
                                }

                            default:
                                guard let sessionKey = decryptedDictionary["sk"] as? Data,
                                      let c = decryptedDictionary["c"] as? Data
                                else { throw ALTServerError.missingKey(key: "sk/c", jsonPayload: self.formatPayloadJSON(decryptedDictionary)) }

                                context.sessionKey = sessionKey

                                let app = "com.apple.gs.xcode.auth"
                                guard let checksum = context.makeChecksum(appName: app) else { throw ALTAppleAPIError.authenticationHandshakeFailed }

                                let parameters = [
                                    "app": [app],
                                    "c": c,
                                    "checksum": checksum,
                                    "cpd": clientDictionary,
                                    "o": "apptokens",
                                    "t": idmsToken,
                                    "u": dsid
                                ] as [String: Any]

                                self.fetchAuthToken(app: app, parameters: parameters, context: context, anisetteData: anisetteData) { result in
                                    switch result {
                                    case let .failure(error): completionHandler(nil, nil, error)
                                    case let .success(token):

                                        let session = ALTAppleAPISession(dsid: dsid, authToken: token, anisetteData: anisetteData, xcodeVersion: xcodeVersion)
                                        self.fetchAccount(session: session) { result in
                                            switch result {
                                            case let .failure(error): completionHandler(nil, nil, error)
                                            case let .success(account): completionHandler(account, session, nil)
                                            }
                                        }
                                    }
                                }
                            }
                        } catch {
                            completionHandler(nil, nil, error)
                        }
                    }
                } catch {
                    completionHandler(nil, nil, error)
                }
            }
        } catch {
            completionHandler(nil, nil, error)
        }
    }
}

private extension ALTAppleAPI {
    func fetchAuthToken(app: String, parameters: [String: Any], context: GSAContext, anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<String, Error>) -> Void) {
        sendAuthenticationRequest(parameters: parameters, anisetteData: anisetteData) { result in
            do {
                let responseDictionary = try result.get()

                guard let encryptedToken = responseDictionary["et"] as? Data else {
                    throw ALTServerError.missingKey(key: "et", jsonPayload: self.formatPayloadJSON(responseDictionary))
                }
                guard let token = encryptedToken.decryptedGCM(context: context) else { throw ALTAppleAPIError.authenticationHandshakeFailed }

                guard let tokensDictionary = self.parsePlistOrJSON(token) else {
                    let rawTokenStr = self.formatPayloadJSON(token)
                    throw ALTServerError.invalidResponseFormat(rawPayload: rawTokenStr)
                }

                guard let appTokens = tokensDictionary["t"] as? [String: Any],
                      let tokens = appTokens[app] as? [String: Any],
                      let authToken = tokens["token"] as? String
                else { throw ALTServerError.missingKey(key: "t/\(app)/token", jsonPayload: self.formatPayloadJSON(tokensDictionary)) }

                completionHandler(.success(authToken))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }

    func requestTrustedDeviceTwoFactorCode(dsid: String,
                                           idmsToken: String,
                                           anisetteData: ALTAnisetteData,
                                           isCodeAlreadySent: Bool = false,
                                           verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                           completionHandler: @escaping (Result<Void, Error>) -> Void) {
        verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode starting for dsid: \(dsid)")
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
        let verifyURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!

        let request = makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)

        let requestCodeHandler: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            let responseStr = data != nil ? self.formatPayloadJSON(data!) : "nil"
            if let error {
                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode request code task failed: \(error) (status: \(statusCode))")
            } else {
                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode request code task succeeded (status: \(statusCode), response: \(responseStr))")
            }
            do {
                guard error == nil else { throw error! }

                func responseHandler(verificationCode: String?) {
                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode received code from user. Has code: \(verificationCode != nil)")
                    do {
                        guard let verificationCode = verificationCode else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                        var request = self.makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
                        request.allHTTPHeaderFields?["security-code"] = verificationCode

                        verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verifying code...")
                        let verifyCodeTask = self.freshAuthenticationDataTask(with: request) { (data, response, error) in
                            do
                            {
                                if let error {
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verification failed with error: \(error)")
                                }
                                guard let data = data else { throw error ?? ALTAppleAPIError.unknown }

                                guard let responseDictionary = self.parsePlistOrJSON(data) else {
                                    let rawVerifyStr = self.formatPayloadJSON(data)
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verify response is invalid: \(rawVerifyStr)")
                                    throw ALTServerError.invalidResponseFormat(rawPayload: rawVerifyStr)
                                }

                                let errorCode = responseDictionary["ec"] as? Int ?? 0
                                guard errorCode != 0 else {
                                    verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode code verified successfully!")
                                    return completionHandler(.success(()))
                                }

                                verboseLog("[AltSign] requestTrustedDeviceTwoFactorCode verification error code: \(errorCode)")
                                switch errorCode {
                                case -21669: throw ALTAppleAPIError.incorrectVerificationCode
                                default:
                                    guard let errorDescription = responseDictionary["em"] as? String else { throw ALTAppleAPIError.unknown }

                                    let localizedDescription = errorDescription + " (\(errorCode))"
                                    throw NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: errorCode, userInfo: [NSLocalizedDescriptionKey: localizedDescription])
                                }
                            } catch {
                                completionHandler(.failure(error))
                            }
                        }

                        verifyCodeTask.resume()
                    } catch {
                        completionHandler(.failure(error))
                    }
                }

                verificationHandler(responseHandler)
            } catch {
                completionHandler(.failure(error))
            }
        }

        if isCodeAlreadySent {
            // hsc=409 means Apple has already delivered the trusted-device
            // code. Requesting another one can be rejected, so prompt for the
            // code immediately.
            requestCodeHandler(nil, nil, nil)
        } else {
            let requestCodeTask = freshAuthenticationDataTask(with: request, completionHandler: requestCodeHandler)
            requestCodeTask.resume()
        }
    }

    func requestSMSTwoFactorCode(dsid: String,
                                 idmsToken: String,
                                 anisetteData: ALTAnisetteData,
                                 verificationHandler: @escaping (@escaping (String?) -> Void) -> Void,
                                 completionHandler: @escaping (Result<Void, Error>) -> Void) {
        verboseLog("[AltSign] requestSMSTwoFactorCode starting for dsid: \(dsid)")
        let requestURL = URL(string: "https://gsa.apple.com/auth/verify/phone")!
        let verifyURL = URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode")!

        var request = makeTwoFactorCodeRequest(url: requestURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
        request.httpMethod = "PUT"

        do {
            let body = [
                "phoneNumber": ["id": 1],
                "mode": "sms"
            ] as [String: Any]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            verboseLog("[AltSign] requestSMSTwoFactorCode serialization failed: \(error)")
            completionHandler(.failure(error))
            return
        }

        let requestCodeTask = freshAuthenticationDataTask(with: request) { data, response, error in
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            let responseStr = data != nil ? self.formatPayloadJSON(data!) : "nil"
            if let error {
                verboseLog("[AltSign] requestSMSTwoFactorCode request code task failed: \(error) (status: \(statusCode))")
            } else {
                verboseLog("[AltSign] requestSMSTwoFactorCode request code task succeeded (status: \(statusCode), response: \(responseStr))")
            }
            do {
                guard error == nil else { throw error! }

                func responseHandler(verificationCode: String?) {
                    verboseLog("[AltSign] requestSMSTwoFactorCode received code from user. Has code: \(verificationCode != nil)")
                    do {
                        guard let verificationCode = verificationCode else { throw ALTAppleAPIError.requiresTwoFactorAuthentication }

                        var request = self.makeTwoFactorCodeRequest(url: verifyURL, dsid: dsid, idmsToken: idmsToken, anisetteData: anisetteData)
                        request.httpMethod = "POST"

                        let body = [
                            "securityCode": ["code": verificationCode],
                            "phoneNumber": ["id": 1],
                            "mode": "sms"
                        ] as [String: Any]
                        request.httpBody = try JSONSerialization.data(withJSONObject: body)

                        verboseLog("[AltSign] requestSMSTwoFactorCode verifying code...")
                        let verifyCodeTask = self.freshAuthenticationDataTask(with: request) { _, response, error in
                            do {
                                if let error {
                                    verboseLog("[AltSign] requestSMSTwoFactorCode verification failed: \(error)")
                                }
                                guard error == nil else { throw error! }

                                guard let httpResponse = response as? HTTPURLResponse,
                                      httpResponse.statusCode == 200,
                                      httpResponse.allHeaderFields.keys.contains("X-Apple-PE-Token") // PE token is included in headers if we sent correct verification code.
                                else {
                                    verboseLog("[AltSign] requestSMSTwoFactorCode verification failed (invalid status code or missing PE token)")
                                    throw ALTAppleAPIError.incorrectVerificationCode
                                }

                                verboseLog("[AltSign] requestSMSTwoFactorCode code verified successfully!")
                                completionHandler(.success(()))
                            } catch {
                                completionHandler(.failure(error))
                            }
                        }

                        verifyCodeTask.resume()
                    } catch {
                        completionHandler(.failure(error))
                    }
                }

                verificationHandler(responseHandler)
            } catch {
                completionHandler(.failure(error))
            }
        }

        requestCodeTask.resume()
    }

    public func fetchAccount(
        session: ALTAppleAPISession,
        completionHandler: @escaping (Result<ALTAccount, Error>) -> Void
    ) {
        verboseLog("[AltSign] fetchAccount starting for dsid: \(session.dsid)")
        let url = URL(string: "viewDeveloper.action", relativeTo: self.baseURL)!

        self.sendRequest(url: url,
                         additionalParameters: nil,
                         session: session,
                         team: nil) { responseDictionary, requestError in
            do {
                if let requestError {
                    verboseLog("[AltSign] fetchAccount request failed: \(requestError)")
                }

                guard let responseDictionary = responseDictionary else {
                    if let requestError { throw requestError }
                    throw ALTAppleAPIError.unknown
                }

                var processError: Error?

                guard let account = self.processResponse(
                    responseDictionary,
                    parseHandler: {
                        guard let dictionary =
                            responseDictionary["developer"] as? [String: Any]
                        else { return nil }
                        return ALTAccount(responseDictionary: dictionary)
                    },
                    resultCodeHandler: nil,
                    error: &processError
                ) as? ALTAccount else {
                    verboseLog("[AltSign] fetchAccount parsing response failed: \(processError ?? ALTAppleAPIError.unknown)")
                    throw processError ?? ALTAppleAPIError.unknown
                }

                verboseLog("[AltSign] fetchAccount succeeded: \(account.name) (Apple ID: \(account.appleID))")
                completionHandler(.success(account))

            } catch {
                completionHandler(.failure(error))
            }
        }
    }
}

private extension ALTAppleAPI {
    func freshAuthenticationDataTask(
        with request: URLRequest,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        let authenticationSession = URLSession(configuration: .ephemeral)
        return authenticationSession.dataTask(with: request) { data, response, error in
            authenticationSession.finishTasksAndInvalidate()
            completionHandler(data, response, error)
        }
    }

    /// 429 重试的间隔；对齐 isideload 的 `RETRY_429_DELAYS = [2s, 5s]`。
    ///
    /// isideload 的注释（iLoader 2.3.4 / upstream a00c3a7）记了原因：
    /// 「iLoader 发现这些 429 常常是瞬时的，重试一次就过了。上游连着重试 10 次；
    ///  但**持续的限流只会随着每次尝试越拖越长**，所以这里再多试两次、间隔开，
    ///  然后放弃。」—— 所以是「少量 + 间隔」，绝不是连打。
    static let grandSlamRetry429Delays: [TimeInterval] = [2, 5]

    func sendAuthenticationRequest(parameters requestParameters: [String: Any], anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<[String: Any], Error>) -> Void) {
        performAuthenticationRequest(parameters: requestParameters,
                                     anisetteData: anisetteData,
                                     remainingRetryDelays: Self.grandSlamRetry429Delays,
                                     completionHandler: completionHandler)
    }

    private func performAuthenticationRequest(parameters requestParameters: [String: Any],
                                              anisetteData: ALTAnisetteData,
                                              remainingRetryDelays: [TimeInterval],
                                              completionHandler: @escaping (Result<[String: Any], Error>) -> Void) {
        sendAuthenticationRequestOnce(parameters: requestParameters, anisetteData: anisetteData) { result in
            guard case .failure(let error) = result,
                  let delay = remainingRetryDelays.first,
                  Self.isThrottlingError(error) else {
                return completionHandler(result)
            }
            let rest = Array(remainingRetryDelays.dropFirst())
            verboseLog("[AltSign] sendAuthenticationRequest throttled; retry in \(delay)s (\(rest.count) left)")
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.performAuthenticationRequest(parameters: requestParameters,
                                                  anisetteData: anisetteData,
                                                  remainingRetryDelays: rest,
                                                  completionHandler: completionHandler)
            }
        }
    }

    /// 是否为 Apple 的限流响应。按**文案**判定：429 被包装进
    /// `ALTServerError.badServerResponse(reason:)` 抛出，没有独立的错误类型可用。
    private static func isThrottlingError(_ error: Error) -> Bool {
        let text = String(describing: error)
        return text.contains("429") || text.lowercased().contains("too many requests")
    }

    func sendAuthenticationRequestOnce(parameters requestParameters: [String: Any], anisetteData: ALTAnisetteData, completionHandler: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            let requestURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!

            let parameters = [
                "Header": ["Version": "1.0.1"],
                "Request": requestParameters
            ]

            verboseLog("[AltSign] sendAuthenticationRequest payload: \(parameters)")

            let httpHeaders = [
                "Content-Type": "text/x-xml-plist",
                "X-MMe-Client-Info": anisetteData.deviceDescription,
                "Accept": "text/x-xml-plist",
                // The User-Agent the anisette server declared together with
                // this device description (isideload's `base_headers` sends
                // the pair verbatim). A hardcoded UA from a different
                // identity family makes the two headers describe different
                // machines. Data produced before the field existed carries
                // an empty string and falls back to the legacy value.
                "User-Agent": anisetteData.userAgent.isEmpty ? "akd/1.0 CFNetwork/808.1.4" : anisetteData.userAgent,
                // SideInstaller's GrandSlam fingerprint carries both of these
                // on every GsService2 request — `init` and `complete` included.
                // Omitting them lets GSA reject the SRP exchange with an HTML
                // 503 before the password is ever checked, which is the
                // immediate-503 symptom seen in the 1.2.7 (16) device log.
                "X-Xcode-Version": grandSlamAuthenticationXcodeVersion,
                "X-Apple-App-Info": grandSlamAuthenticationAppInfo,
                // Apple can return an edge 503 for a reused GSA connection.
                // Authentication sessions are already short-lived; this also
                // tells the transport not to retain this connection.
                "Connection": "close"
            ]

            let bodyData = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)

            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

            // GSA can reject a GrandSlam exchange after a prior request on the
            // same idle connection. Use a short-lived session so each init or
            // complete request starts with a fresh connection.
            let authenticationSession = URLSession(configuration: .ephemeral)
            let dataTask = authenticationSession.dataTask(with: request) { (data, response, error) in
                authenticationSession.finishTasksAndInvalidate()
                do
                {
                    if let error {
                        verboseLog("[AltSign] sendAuthenticationRequest failed with error: \(error)")
                    }
                    guard let data = data, !data.isEmpty else {
                        let err = error ?? ALTServerError.badServerResponse(reason: "Server returned empty response (Content-Length: 0) — session may have timed out", jsonPayload: "0 bytes")
                        throw err
                    }

                    // Apple answers a throttled sign-in attempt with an HTML 429,
                    // not a plist, so it used to fall through to
                    // `invalidResponseFormat` and surface as "Apple ID 验证失败"
                    // (SEAL-AUTH-107a) -- which reads as a bad account and sends
                    // people into retry loops that only extend the window. Name it
                    // for what it is instead. isideload treats the same status the
                    // same way ("a lasting limit only gets longer with every
                    // attempt"), so surface a distinct error the caller can word.
                    if let httpResponse = response as? HTTPURLResponse,
                       httpResponse.statusCode == 429 {
                        let rawResponse = self.formatPayloadJSON(data)
                        verboseLog("[AltSign] sendAuthenticationRequest was throttled: HTTP 429")
                        throw ALTServerError.badServerResponse(reason: "Apple is throttling sign-in attempts (HTTP 429 Too Many Requests)", jsonPayload: rawResponse)
                    }

                    guard let responseDictionary = self.parsePlistOrJSON(data),
                          let dictionary = responseDictionary["Response"] as? [String: Any] ?? responseDictionary["response"] as? [String: Any] ?? (responseDictionary["Status"] != nil ? responseDictionary : nil),
                          let status = dictionary["Status"] as? [String: Any] ?? responseDictionary["Status"] as? [String: Any]
                    else {
                        let rawResponse = self.formatPayloadJSON(data)
                        verboseLog("[AltSign] sendAuthenticationRequest response is invalid or could not be parsed: \(rawResponse)")
                        throw ALTServerError.invalidResponseFormat(rawPayload: rawResponse)
                    }

                    verboseLog("[AltSign] sendAuthenticationRequest response Status: \(status)")
                    verboseLog("[AltSign] sendAuthenticationRequest response Data: \(dictionary)")

                    // GSA 的 `Status` 是一组固定字段，逐项摊平打印。
                    // 排障时它们区分得开三种完全不同的拒绝（2026-10-16 独立探测实测）：
                    //   无设备证明   → hsc=200  ec=-80009  em="MID is invalid."
                    //   设备证明不合格 → hsc=433  ec=-29004  em="…possible environment mismatch."
                    //   真实凭据走到更深 → hsc=500  ec=-80045  em="This action cannot be completed at this time."
                    // `hsc` 最有判别力：它说明请求走到了哪一道校验。
                    verboseLog("""
                    [AltSign] GSA Status 全字段:
                      ec    = \(status["ec"].map { "\($0)" } ?? "nil")
                      em    = \(status["em"].map { "\($0)" } ?? "nil")
                      ed    = \(status["ed"].map { "\($0)" } ?? "nil")
                      hsc   = \(status["hsc"].map { "\($0)" } ?? "nil")
                      rsh   = \(status["rsh"].map { "\($0)" } ?? "nil")
                      ptxid = \(status["ptxid"].map { "\($0)" } ?? "nil")
                    """)

                    let errorCode = status["ec"] as? Int ?? 0
                    guard errorCode != 0 else { return completionHandler(.success(dictionary)) }

                    verboseLog("[AltSign] sendAuthenticationRequest status returned error code: \(errorCode)")

                    switch errorCode
                    {
                    case -20101, -22406: throw ALTAppleAPIError.incorrectCredentials
                    // `-22421` **不能**在这里直接归成 invalidAnisetteData。
                    //
                    // Apple 用它来表达「anisette 需要重新同步」：此时响应里同时带着
                    // `hsc = 434` 与 `X-Apple-I-MD-DATA`（SIM），后者正是重同步要回送的
                    // 凭据。以前在 switch 里直接抛错，就绕过了下面提取 SIM 的分支 ——
                    // 真机日志因此一直显示「SRP 登录失败（无 SIM 同步指令）」，
                    // 而 Apple 其实已经下发了 SIM。
                    //
                    // 让它落到 default 分支：那里会把 SIM 与 hsc 放进 userInfo，
                    // 上层 `AppleAccountClient.resyncSIM(from:)` 才能取到并触发 resync。
                    // 取不到 SIM 时（旧式回复只有 hsc）仍按 invalidAnisetteData 处理。
                    case -22421 where Self.resyncSIM(in: dictionary, status: status) == nil:
                        throw ALTAppleAPIError.invalidAnisetteData
                    default:
                        guard let errorDescription = status["em"] as? String else { throw ALTAppleAPIError.unknown }

                        let localizedDescription = errorDescription + " (\(errorCode))"
                        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: localizedDescription]
                        // `Status` only carries the outcome. When Apple requests an
                        // Anisette resync, SIM is a sibling in `Response`, not a
                        // status field. Keep the status fallback for older replies.
                        if let hsc = dictionary["hsc"] ?? status["hsc"] {
                            userInfo["ALTAppleAPIStatusHSC"] = hsc
                        }
                        if let sim = Self.resyncSIM(in: dictionary, status: status) {
                            userInfo["ALTAppleAPIResyncSIM"] = sim
                        }
                        // Apple 在要求 resync 时还会给 `X-Apple-I-MD-Cmd-Target`
                        // （实测值 `native`）。isideload 把它一并回送给 anisette
                        // 服务器，这里透出去让上层能用同样的方式重同步。
                        if let target = dictionary["X-Apple-I-MD-Cmd-Target"] ?? status["X-Apple-I-MD-Cmd-Target"] {
                            userInfo["ALTAppleAPIResyncCmdTarget"] = target
                        }
                        throw NSError(domain: ALTUnderlyingAppleAPIErrorDomain, code: errorCode, userInfo: userInfo)
                    }
                } catch {
                    verboseLog("[AltSign] sendAuthenticationRequest failed during response processing with error: \(error)")
                    completionHandler(.failure(error))
                }
            }

            dataTask.resume()
        } catch {
            verboseLog("[AltSign] sendAuthenticationRequest failed before sending: \(error)")
            completionHandler(.failure(error))
        }
    }

    /// 取 Apple 下发的 resync 凭据（SIM）。
    ///
    /// Apple 要求 anisette 重新同步时，响应里带 `X-Apple-I-MD-DATA`：
    /// - 多数回复是 **base64 字符串**（真机实测
    ///   `AAAABOyLnRH7R3k+P8CGlOM8JZuN1UBO4iZLsGrRfsQ=`），回送给 anisette 服务器的
    ///   `/v3/get_headers` 时用原样的 base64；
    /// - plist 的 `<data>` 会被解析成 `Data`，此时补一次 base64 编码，保证线上格式一致。
    ///
    /// 它是 `Status` 的**兄弟节点**（在 `Response` 里），不是 `Status` 的字段，
    /// 所以两处都找一遍以兼容旧式回复。
    static func resyncSIM(in dictionary: [String: Any], status: [String: Any]) -> String? {
        guard let raw = dictionary["X-Apple-I-MD-DATA"] ?? status["X-Apple-I-MD-DATA"] else {
            return nil
        }
        if let string = raw as? String, string.isEmpty == false { return string }
        if let data = raw as? Data, data.isEmpty == false { return data.base64EncodedString() }
        return nil
    }

    func makeTwoFactorCodeRequest(url: URL,
                                  dsid: String,
                                  idmsToken: String,
                                  anisetteData: ALTAnisetteData) -> URLRequest {
        let identityToken = dsid + ":" + idmsToken

        let identityTokenData = identityToken.data(using: .utf8)!
        let encodedIdentityToken = identityTokenData.base64EncodedString()

        // Keep every /auth request on the same client identity as the GrandSlam
        // SRP exchange. That identity comes from the anisette server's
        // /v3/client_info and is used verbatim (SideInstaller's isideload does the
        // same in remote_v3/mod.rs); servers whose identity Apple rejects are
        // skipped before we ever get here. SideInstaller's working shape is kept:
        // its phone endpoints use JSON while the trusted-device endpoints use
        // XML plist.
        let isPhoneEndpoint = url.path == "/auth/verify/phone" || url.path == "/auth/verify/phone/securitycode"
        let httpHeaders = [
            "Accept": isPhoneEndpoint ? "application/json" : "text/x-xml-plist",
            "Accept-Language": "en-us",
            "Content-Type": isPhoneEndpoint ? "application/json" : "text/x-xml-plist",
            // Same pairing rule as the GrandSlam exchange above: the server's
            // declared User-Agent, legacy value only when the data predates it.
            "User-Agent": anisetteData.userAgent.isEmpty ? "akd/1.0 CFNetwork/808.1.4" : anisetteData.userAgent,
            "X-Apple-App-Info": grandSlamAuthenticationAppInfo,
            "X-Xcode-Version": grandSlamAuthenticationXcodeVersion,
            "X-Apple-Identity-Token": encodedIdentityToken,
            "X-Apple-I-MD-M": anisetteData.machineID,
            "X-Apple-I-MD": anisetteData.oneTimePassword,
            "X-Apple-I-MD-LU": anisetteData.localUserID,
            "X-Apple-I-MD-RINFO": "\(anisetteData.routingInfo)",
            "X-Mme-Device-Id": anisetteData.deviceUniqueIdentifier,
            "X-MMe-Client-Info": anisetteData.deviceDescription,
            // 与 cpd 同一条对齐规则：isideload 的请求头不发 Client-Time / Locale /
            // TimeZone（`get_headers()` 里被注释掉）。Locale 会是设备的 zh_CN，
            // 与身份串里的 en_US 不一致；TimeZone 是猜的占位值。都不发。
            "Connection": "close"
        ]

        var request = URLRequest(url: url)
        httpHeaders.forEach { request.addValue($0.value, forHTTPHeaderField: $0.key) }

        return request
    }
}

private extension ALTAppleAPI {
    func parsePlistOrJSON(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            ?? (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    func formatPayloadJSON(_ payload: Any) -> String {
        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        if let data = payload as? Data {
            if let str = String(data: data, encoding: .utf8) {
                return formatPayloadString(str)
            }
            return data.hexEncodedString()
        }
        if let str = payload as? String {
            return formatPayloadString(str)
        }
        return "\(payload)"
    }

    private func formatPayloadString(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            return prettyPrintXML(trimmed)
        }
        return trimmed
    }

    private func prettyPrintXML(_ rawXML: String) -> String {
        let pattern = "(<[^>]+>)|([^<]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return rawXML
        }

        let nsString = rawXML as NSString
        let matches = regex.matches(in: rawXML, options: [], range: NSRange(location: 0, length: nsString.length))

        var result: [String] = []
        var indentLevel = 0

        for match in matches {
            var token = nsString.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }

            // Collapse internal newlines and multiple spaces inside XML tags
            if token.hasPrefix("<") && !token.hasPrefix("<![CDATA[") {
                token = token.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            }

            if token.hasPrefix("</") {
                indentLevel = max(0, indentLevel - 1)
                let indent = String(repeating: "  ", count: indentLevel)
                result.append("\(indent)\(token)")
            } else if token.hasPrefix("<?") || token.hasPrefix("<!") || token.hasSuffix("/>") {
                let indent = String(repeating: "  ", count: indentLevel)
                result.append("\(indent)\(token)")
            } else if token.hasPrefix("<") {
                let indent = String(repeating: "  ", count: indentLevel)
                result.append("\(indent)\(token)")
                indentLevel += 1
            } else {
                let baseIndent = String(repeating: "  ", count: indentLevel)
                let subLines = token.components(separatedBy: .newlines)
                var cssIndent = 0
                for subLine in subLines {
                    let subTrimmed = subLine.trimmingCharacters(in: .whitespaces)
                    if subTrimmed.isEmpty { continue }

                    if subTrimmed.hasPrefix("}") {
                        cssIndent = max(0, cssIndent - 1)
                    }

                    let extraIndent = String(repeating: "  ", count: cssIndent)
                    result.append("\(baseIndent)\(extraIndent)\(subTrimmed)")

                    if subTrimmed.hasSuffix("{") {
                        cssIndent += 1
                    }
                }
            }
        }

        return result.joined(separator: "\n")
    }
}

// MARK: - Data decryption helpers (used only within this file)

private extension Data {

    /* AES-CBC-PKCS7: key and IV derived from the SRP session via HMAC */
    func decryptedCBC(context: GSAContext) -> Data? {
        guard let key = context.makeHMACKey("extra data key:"),
              let iv  = context.makeHMACKey("extra data iv:")
        else { return nil }

        return CoreCryptoBridge.aesCBCDecrypt(key: key, iv: iv, ciphertext: self)
    }

    /* AES-GCM: layout is [3-byte version | 16-byte IV | ciphertext | 16-byte tag] */
    func decryptedGCM(context: GSAContext) -> Data? {
        guard let sessionKey = context.sessionKey else { return nil }

        let versionSize = 3   // version prefix — treated as AAD
        let ivSize      = 16  // nonce
        let tagSize     = 16  // GCM authentication tag

        guard self.count > versionSize + ivSize + tagSize else { return nil }

        let aad        = Data(self[..<versionSize])
        let nonce      = Data(self[versionSize ..< versionSize + ivSize])
        let ciphertext = Data(self[versionSize + ivSize ..< self.count - tagSize])
        let tag        = Data(self[(self.count - tagSize)...])

        return CoreCryptoBridge.aesGCMDecrypt(key: sessionKey, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag)
    }
}
