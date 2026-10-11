"""Static regression checks for failure-contract fields until macOS CI compiles Swift."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FailureContractSourceTests(unittest.TestCase):
    def test_service_unavailable_factory_has_no_network_route_guess(self) -> None:
        source = (ROOT / "Seal/Core/Accounts/AppleServiceFailurePolicy.swift").read_text(
            encoding="utf-8"
        )
        factory = source.split("static func rateLimitedFailure", 1)[1].split(
            "private static func messageIndicates503", 1
        )[0]

        self.assertIn("condition: .appleServiceUnavailable", factory)
        self.assertIn("action: .waitThenRetry", factory)
        self.assertIn("retryDisposition: .manual", factory)
        self.assertIn("origin: .applePortal", factory)
        self.assertNotIn("海外", factory)
        self.assertNotIn("节点", factory)

    def test_two_factor_factory_declares_account_recovery_semantics(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift").read_text(
            encoding="utf-8"
        )
        factory = source.split("static func twoFactorFailure", 1)[1]

        self.assertIn("condition: .twoFactorAuthenticationRequired", factory)
        self.assertIn("action: .enterNewVerificationCode", factory)
        self.assertIn("route: .account", factory)
        self.assertIn("retryDisposition: .manual", factory)
        self.assertIn("operation: .authenticateAccount", factory)
        self.assertIn("origin: .authentication", factory)

    def test_explicit_account_rejections_keep_their_distinct_recovery_contracts(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        verification_code = source.split(
            "catch ALTAppleAPIError.incorrectVerificationCode", 1
        )[1].split("catch ALTAppleAPIError.incorrectCredentials", 1)[0]
        initial_credentials = source.split(
            "catch ALTAppleAPIError.incorrectCredentials", 1
        )[1].split("catch ALTAppleAPIError.invalidAnisetteData", 1)[0]
        validation_credentials = source.split(
            "func validate(", 1
        )[1].split("catch ALTAppleAPIError.incorrectCredentials", 1)[1].split(
            "catch let failure as ImportFailure", 1
        )[0]

        self.assertIn("condition: .verificationCodeRejected", verification_code)
        self.assertIn("action: .enterNewVerificationCode", verification_code)
        self.assertIn("operation: .authenticateAccount", verification_code)

        self.assertIn("condition: .credentialsRejected", initial_credentials)
        self.assertIn("action: .reauthenticateAccount", initial_credentials)
        self.assertIn("operation: .authenticateAccount", initial_credentials)

        self.assertIn("condition: .credentialsRejected", validation_credentials)
        self.assertIn("action: .reauthenticateAccount", validation_credentials)
        self.assertIn("operation: .validateAccount", validation_credentials)

    def test_missing_and_unverified_accounts_are_not_emitted_as_one_failure(self) -> None:
        source = (ROOT / "Seal/Core/Accounts/AccountAvailabilityFailure.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn('code: "SEAL-AUTH-104h"', source)
        self.assertIn("condition: .signingAccountUnavailable", source)
        self.assertIn("action: .addAccount", source)
        self.assertIn('code: "SEAL-AUTH-104i"', source)
        self.assertIn("condition: .accountVerificationRequired", source)
        self.assertIn("action: .reauthenticateAccount", source)

    def test_recorded_renewal_account_failures_keep_their_team_safe_actions(self) -> None:
        source = (ROOT / "Seal/Features/Apps/AppsViewModel.swift").read_text(
            encoding="utf-8"
        )
        needs_verification = source.split(
            "case .recordedAccountNeedsVerification", 1
        )[1].split("case .recordedAccountMissing", 1)[0]
        missing_original = source.split(
            "case .recordedAccountMissing", 1
        )[1].split("case .noSelectableAccount", 1)[0]

        self.assertIn("condition: .accountVerificationRequired", needs_verification)
        self.assertIn("action: .reauthenticateAccount", needs_verification)
        self.assertIn("operation: .renew", needs_verification)
        self.assertIn("condition: .recordedSigningIdentityUnavailable", missing_original)
        self.assertIn("action: .addAccount", missing_original)
        self.assertIn("operation: .renew", missing_original)

    def test_authentication_timeout_and_team_lookup_keep_distinct_facts(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        timeout = source.split("catch let error as HardTimeout.TimeoutError", 1)[1].split(
            "    }\n\n    /// 自动重新登录", 1
        )[0]
        team_lookup = source.split("case .teamLookup:", 1)[1].split("    }\n}", 1)[0]

        self.assertIn("condition: .authenticationTimedOut", timeout)
        self.assertIn("action: .waitThenRetry", timeout)
        self.assertIn("operation: .authenticateAccount", timeout)
        self.assertNotIn("更换网络", timeout)

        self.assertIn("condition: .developerTeamLookupFailed", team_lookup)
        self.assertIn("action: .retry", team_lookup)
        self.assertIn("operation: .authenticateAccount", team_lookup)

    def test_anisette_factory_distinguishes_rejection_unavailability_and_service_wait(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        factory = source.split("if let anisetteError", 1)[1].split(
            "// 双重认证必须排在", 1
        )[0]

        self.assertIn('code: "SEAL-ANI-110",', factory)
        self.assertIn("condition: .authenticationEnvironmentRejected", factory)
        self.assertIn("condition: .authenticationEnvironmentUnavailable", factory)
        self.assertIn("condition: .authenticationEnvironmentServiceUnavailable", factory)
        self.assertIn("action: .waitThenRetry", factory)
        self.assertIn("operation: .authenticateAccount", factory)
        self.assertIn("origin: .authentication", factory)

    def test_authentication_handshake_rejection_does_not_guess_network_remediation(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        handshake = source.split("case .authenticationHandshakeFailed", 1)[1].split(
            "if error is AnisetteV3Error", 1
        )[0]

        self.assertIn("condition: .authenticationHandshakeRejected", handshake)
        self.assertIn("action: .waitThenRetry", handshake)
        self.assertIn("operation: .authenticateAccount", handshake)
        self.assertNotIn("更换网络", handshake)
        self.assertNotIn("系统时间", handshake)

    def test_unclassified_account_validation_is_transparent_and_waits_before_reauth(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Accounts/AppleAccountClient.swift").read_text(
            encoding="utf-8"
        )
        validation = source.split("func validate(", 1)[1].split(
            "nonisolated static func mask", 1
        )[0]

        self.assertIn('code: "SEAL-VERIFY-500a"', validation)
        self.assertIn("condition: .unexpected", validation)
        self.assertIn("action: .waitThenRetry", validation)
        self.assertIn("operation: .validateAccount", validation)
        self.assertIn("origin: .authentication", validation)
        self.assertIn("账号状态未改变", validation)

    def test_local_import_storage_boundaries_keep_only_source_proven_recovery_actions(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Storage/AppFileStore.swift").read_text(
            encoding="utf-8"
        )

        expectations = {
            "SEAL-IPA-201": (".localStorageWriteFailed", ".restartSeal"),
            "SEAL-IPA-202": (".unexpected", ".reimportIPA"),
            "SEAL-IPA-203": (".localStorageWriteFailed", ".reimportIPA"),
            "SEAL-IPA-204": (".unexpected", ".reimportIPA"),
            "SEAL-IPA-211a": (".unexpected", ".reimportIPA"),
            "SEAL-IPA-212": (".localStorageWriteFailed", ".reimportIPA"),
            "SEAL-IPA-207": (".unexpected", ".reimportIPA"),
            "SEAL-IPA-208": (".unexpected", ".reimportIPA"),
            "SEAL-IPA-209": (".unexpected", ".reimportIPA"),
            "SEAL-IPA-210": (".unexpected", ".reimportIPA"),
        }
        for code, (condition, action) in expectations.items():
            failure = source.split(f'code: "{code}",', 1)[1].split(
                "\n            )", 1
            )[0]
            self.assertIn(f"condition: {condition}", failure, code)
            self.assertIn(f"action: {action}", failure, code)
            self.assertIn("retryDisposition: .manual", failure, code)
            self.assertIn("operation: .importIPA", failure, code)
            self.assertIn("origin: .fileStore", failure, code)

        self.assertNotIn("condition: .deviceStorageFull", source)

    def test_structured_reimport_action_opens_the_importer_without_a_code_prefix_guess(self) -> None:
        source = (ROOT / "Seal/Features/Apps/AppsViewModel.swift").read_text(
            encoding="utf-8"
        )
        recovery = source.split("func performAlertRecovery", 1)[1].split(
            "    func openSettings", 1
        )[0]

        self.assertIn("if failure.hasStructuredSemantics", recovery)
        self.assertIn("case .reimportIPA:", recovery)
        self.assertIn("presentImporter()", recovery)

    def test_import_workflow_failures_keep_their_actual_recovery_owner(self) -> None:
        source = (ROOT / "Seal/Core/Import/ImportWorkflow.swift").read_text(
            encoding="utf-8"
        )

        parse_failure = source.split("private static func importFailure", 1)[1].split(
            "private static let persistenceFailure", 1
        )[0]
        persistence_failure = source.split("private static let persistenceFailure", 1)[1].split(
            "private static let temporaryCleanupFailure", 1
        )[0]
        replacement_failure = source.split("guard let replacement", 1)[1].split(
            "let preferenceSource", 1
        )[0]

        self.assertIn('code: "SEAL-IPA-200"', parse_failure)
        self.assertIn("action: .reimportIPA", parse_failure)
        self.assertIn("operation: .importIPA", parse_failure)
        self.assertIn("origin: .unknown", parse_failure)

        self.assertIn('code: "SEAL-IPA-205"', persistence_failure)
        self.assertIn("action: .retry", persistence_failure)
        self.assertIn("retryDisposition: .manual", persistence_failure)
        self.assertNotIn("存储空间", persistence_failure)
        self.assertIn("operation: .importIPA", persistence_failure)
        self.assertIn("origin: .unknown", persistence_failure)

        self.assertIn('code: "SEAL-IPA-217"', replacement_failure)
        self.assertIn("action: .reimportIPA", replacement_failure)
        self.assertIn("retryDisposition: .manual", replacement_failure)
        self.assertIn("operation: .importIPA", replacement_failure)

    def test_structured_import_recovery_chooses_the_action_instead_of_always_retrying(self) -> None:
        root = (ROOT / "Seal/Features/Apps/AppsRootView.swift").read_text(
            encoding="utf-8"
        )
        view_model = (ROOT / "Seal/Features/Apps/AppsViewModel.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn("await viewModel.performImportPrimaryAction()", root)
        recovery = view_model.split("func performImportPrimaryAction", 1)[1].split(
            "func cancelImport", 1
        )[0]
        self.assertIn("case .retry:", recovery)
        self.assertIn("await retryImport()", recovery)
        self.assertIn("case .reimportIPA:", recovery)
        self.assertIn("await reselectImportIPA()", recovery)

    def test_incomplete_profile_only_result_retries_instead_of_claiming_app_id_loss(self) -> None:
        source = (ROOT / "Seal/Core/Renewal/ProfileOnlyRenewalRecordUpdater.swift").read_text(
            encoding="utf-8"
        )

        for code in ("340", "341", "342"):
            failure = source.split(f'code: "SEAL-PROFILE-{code}",', 1)[1].split(
                "\n                )", 1
            )[0]
            self.assertIn("condition: .provisioningProfileIncomplete", failure)
            self.assertIn("action: .retry", failure)
            self.assertIn("retryDisposition: .manual", failure)
            self.assertIn("operation: .renew", failure)
            self.assertIn("origin: .provisioning", failure)
            self.assertNotIn("fullResign", failure)

    def test_terminal_install_outcomes_have_distinct_codes_and_actions(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift").read_text(
            encoding="utf-8"
        )
        app_limit = source.split("// 2) 免费账号设备级应用上限", 1)[1].split(
            "// 3) 签名产物完整性", 1
        )[0]
        invalid_artifact = source.split("// 3) 签名产物完整性", 1)[1].split(
            "// 4) `ApplicationVerificationFailed`", 1
        )[0]
        unknown_rejection = source.split("// 4) `ApplicationVerificationFailed`", 1)[1].split(
            "// 5) 设备未连接", 1
        )[0]

        self.assertIn('code: "SEAL-INSTALL-702l"', app_limit)
        self.assertIn("action: .removeInstalledApp", app_limit)
        self.assertIn('code: "SEAL-INSTALL-702v"', invalid_artifact)
        self.assertIn("action: .fullResign", invalid_artifact)
        self.assertIn('code: "SEAL-INSTALL-702u"', unknown_rejection)
        self.assertIn("action: .copyDiagnostics", unknown_rejection)

    def test_app_id_registration_limit_waits_without_guessing_a_network_fix(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Signing/ApplePortalSigningService.swift").read_text(
            encoding="utf-8"
        )
        limit = source.split("if Self.isAppIDRegistrationLimit", 1)[1].split(
            "        }\n\n        return ImportFailure(", 1
        )[0]

        self.assertIn('code: "SEAL-APPID-304"', limit)
        self.assertIn("condition: .appIDRegistrationLimit", limit)
        self.assertIn("action: .waitThenRetry", limit)
        self.assertIn("operation: .sign", limit)
        self.assertIn("origin: .applePortal", limit)
        self.assertNotIn("检查网络", limit)

    def test_unclassified_app_id_creation_failure_does_not_invent_a_cause(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Signing/ApplePortalSigningService.swift").read_text(
            encoding="utf-8"
        )
        code_offset = source.index('code: "SEAL-APPID-303"')
        start = source.rindex("        return ImportFailure(", 0, code_offset)
        end = source.index("        )\n    }", code_offset)
        generic = source[start:end]

        self.assertIn('code: "SEAL-APPID-303"', source)
        self.assertIn("condition: .unexpected", generic)
        self.assertIn("action: .waitThenRetry", generic)
        self.assertIn("retryDisposition: .manual", generic)
        self.assertIn("operation: .sign", generic)
        self.assertIn("origin: .applePortal", generic)
        self.assertNotIn("检查网络", generic)
        self.assertNotIn("重新验证 Apple ID", generic)

    def test_app_id_session_expiry_does_not_claim_a_confirmed_rate_limit(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Signing/ApplePortalSigningService.swift").read_text(
            encoding="utf-8"
        )
        app_id_failure = source.index("fileprivate static func appIDFailure")
        start = source.index("if ApplePortalSigningService.isSessionExpiredError", app_id_failure)
        end = source.index("        if nsError.code == 3011", start)
        session_failure = source[start:end]

        self.assertIn('code: "SEAL-AUTH-107"', session_failure)
        self.assertIn("condition: .unexpected", session_failure)
        self.assertIn("action: .waitThenRetry", session_failure)
        self.assertIn("retryDisposition: .manual", session_failure)
        self.assertIn("operation: .sign", session_failure)
        self.assertIn("origin: .applePortal", session_failure)
        self.assertNotIn("说明登录状态其实还在", session_failure)
        self.assertNotIn("更常见的原因", session_failure)

    def test_ambiguous_certificate_auth_failure_waits_without_claiming_a_cause(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Signing/ApplePortalSigningService.swift").read_text(
            encoding="utf-8"
        )
        certificate_failure = source.split("private static func certificateFailure", 1)[1]
        start = certificate_failure.index('if normalized.contains("unauthorized")')
        code_offset = certificate_failure.index('code: "SEAL-AUTH-102c"', start)
        end = certificate_failure.index("        }\n\n        return ImportFailure(", code_offset)
        ambiguous_auth = certificate_failure[start:end]

        self.assertIn('code: "SEAL-AUTH-102c"', ambiguous_auth)
        self.assertIn("condition: .unexpected", ambiguous_auth)
        self.assertIn("action: .waitThenRetry", ambiguous_auth)
        self.assertIn("retryDisposition: .manual", ambiguous_auth)
        self.assertIn("operation: .sign", ambiguous_auth)
        self.assertIn("origin: .applePortal", ambiguous_auth)
        self.assertNotIn("两种常见成因", ambiguous_auth)
        self.assertNotIn("更可能是后者", ambiguous_auth)

    def test_unclassified_certificate_preparation_failure_does_not_claim_network_or_storage(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Signing/ApplePortalSigningService.swift").read_text(
            encoding="utf-8"
        )
        code_offset = source.index('code: "SEAL-CERT-203"')
        start = source.rindex("        return ImportFailure(", 0, code_offset)
        end = source.index("        )\n    }", code_offset)
        generic = source[start:end]

        self.assertIn("condition: .unexpected", generic)
        self.assertIn("action: .waitThenRetry", generic)
        self.assertIn("retryDisposition: .manual", generic)
        self.assertIn("operation: .sign", generic)
        self.assertIn("origin: .applePortal", generic)
        self.assertNotIn("检查网络", generic)
        self.assertNotIn("存储空间", generic)

    def test_certificate_connection_signal_does_not_prescribe_local_vpn_or_wifi(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Signing/ApplePortalSigningService.swift").read_text(
            encoding="utf-8"
        )
        certificate_failure = source.split("private static func certificateFailure", 1)[1]
        start = certificate_failure.index('if normalized.contains("network")')
        code_offset = certificate_failure.index('code: "SEAL-CERT-205"', start)
        end = certificate_failure.index("        }\n\n        if normalized.contains(\"unauthorized\")", code_offset)
        connection_failure = certificate_failure[start:end]

        self.assertIn("condition: .unexpected", connection_failure)
        self.assertIn("action: .retry", connection_failure)
        self.assertIn("retryDisposition: .manual", connection_failure)
        self.assertIn("operation: .sign", connection_failure)
        self.assertIn("origin: .applePortal", connection_failure)
        self.assertNotIn("检查网络", connection_failure)
        self.assertNotIn("打开 LocalDevVPN", connection_failure)

    def test_apple_request_transport_failure_has_its_own_fact_and_no_proxy_advice(self) -> None:
        contract = (ROOT / "Seal/Core/Import/FailureContract.swift").read_text(
            encoding="utf-8"
        )
        policy = (ROOT / "Seal/Core/Accounts/AppleServiceFailurePolicy.swift").read_text(
            encoding="utf-8"
        )
        classifier = (ROOT / "Seal/Core/Import/FailureClassifier.swift").read_text(
            encoding="utf-8"
        )
        factory = policy.split("static func networkFailure", 1)[1].split(
            "/// Apple 服务端返回 503", 1
        )[0]

        self.assertIn("case appleRequestTransportUnavailable", contract)
        self.assertIn("condition: .appleRequestTransportUnavailable", factory)
        self.assertIn("action: .retry", factory)
        self.assertIn("retryDisposition: .manual", factory)
        self.assertIn("origin: .applePortal", factory)
        self.assertNotIn("梯子", factory)
        self.assertNotIn("检查网络", factory)
        network_branch = classifier.split("if AppleServiceFailurePolicy.isNetworkError", 1)[1].split(
            "        }\n\n        return ImportFailure(", 1
        )[0]
        self.assertIn("condition: .appleRequestTransportUnavailable", network_branch)

    def test_explicit_pairing_rejection_routes_to_pairing_instead_of_reinstall(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift").read_text(
            encoding="utf-8"
        )
        pairing = source.split("if normalized.contains(\"pair\")", 1)[1].split(
            "if normalized.contains(\"trust\")", 1
        )[0]

        self.assertIn('code: "SEAL-INSTALL-703"', pairing)
        self.assertIn("condition: .pairingRequired", pairing)
        self.assertIn("action: .repairPairing", pairing)
        self.assertIn("route: .pairing", pairing)
        self.assertIn("operation: .install", pairing)

    def test_install_verification_only_reinstalls_after_a_trusted_positive_control(self) -> None:
        source = (ROOT / "Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift").read_text(
            encoding="utf-8"
        )
        verification = source.split("static func verificationFailure(", 1)[1].split(
            "    #if !targetEnvironment", 1
        )[0]
        unverifiable = verification.split("guard positiveControl == .installed else", 1)[1].split(
            "        }\n        return ImportFailure(", 1
        )[0]
        definitive = verification.rsplit("        return ImportFailure(", 1)[1]

        self.assertIn('code: "SEAL-INSTALL-707b"', unverifiable)
        self.assertIn("condition: .deviceServiceUnavailable", unverifiable)
        self.assertIn("action: .checkInstallationResult", unverifiable)
        self.assertIn("暂不重新安装", unverifiable)

        self.assertIn('code: "SEAL-INSTALL-707a"', definitive)
        self.assertIn("condition: .installationVerificationFailed", definitive)
        self.assertIn("action: .reinstallFromSignedArtifact", definitive)
        self.assertIn("operation: .install", definitive)


if __name__ == "__main__":
    unittest.main()
