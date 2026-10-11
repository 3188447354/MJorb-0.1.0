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
