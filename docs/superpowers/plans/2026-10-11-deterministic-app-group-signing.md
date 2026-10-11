# Deterministic App Group Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every complete Seal signing route emit deterministic App Group entitlement order without deleting an Apple App ID.

**Architecture:** Canonicalize only App Group strings in the actual build dependency, `Vendor/SideSign`, at the single point where a profile becomes signed-binary entitlements. Keep profile-only renewal profile-only; remove the LiveContainer2-specific destructive migration.

**Tech Stack:** Swift 6, Swift Testing, vendored SideSign, XcodeGen, GitHub Actions complete iOS workflow.

---

### Task 1: Test and implement the real signer boundary

**Files:**
- Modify: `Vendor/SideSign/Package.swift`
- Modify: `Vendor/SideSign/Sources/CodeSigning/CodeSignerAPI.swift`
- Create: `Vendor/SideSign/Tests/SideSignTests/AppGroupEntitlementCanonicalizerTests.swift`

- [ ] Add a SideSign test target and write failing tests for:
  - inverse App Group order yields the same sorted array;
  - duplicate groups are removed;
  - `NSArray` and Swift arrays of strings work;
  - a mixed-type group array remains untouched;
  - `keychain-access-groups` remains untouched.
- [ ] Run `swift test --package-path Vendor/SideSign --filter AppGroupEntitlementCanonicalizerTests` and observe the expected missing-helper failure.
- [ ] Add an internal `AppGroupEntitlementCanonicalizer`. It only handles `com.apple.security.application-groups`, requires every value to be a string, then applies `Array(Set(groups)).sorted()`.
- [ ] Call it from `AppBundleSigner.prepare` immediately after reading `matchedProfile.entitlements`, so main apps and every extension share one signed-binary rule.
- [ ] Run `swift test --package-path Vendor/SideSign`; commit `fix: canonicalize signed app group entitlements`.

### Task 2: Test main-app and extension coverage

**Files:**
- Modify: `Vendor/SideSign/Tests/SideSignTests/AppGroupEntitlementCanonicalizerTests.swift`
- Inspect: `Vendor/SideSign/Sources/CodeSigning/CodeSignerAPI.swift:84-203`

- [ ] Build a minimal main-bundle plus extension fixture with profiles containing opposite App Group order.
- [ ] Write the failing assertion that emitted entitlement plists for both targets contain the same canonical group order.
- [ ] Run the focused test and confirm it reaches `AppBundleSigner.prepare`.
- [ ] Keep a single canonicalization call; make the fixture pass through that existing boundary.
- [ ] Run all vendor tests; commit `test: cover deterministic app groups for extensions`.

### Task 3: Remove destructive portal behavior

**Files:**
- Modify: `Seal/Infrastructure/Signing/ApplePortalSigningService.swift:2386-2439`
- Modify: `Scripts/verify-release-safety.py:1328-1345`

- [ ] Add a failing release-safety assertion that normal signing contains neither the LC2 bundle-ID literal nor the one-time UserDefaults migration flag.
- [ ] Run `python Scripts/verify-release-safety.py` and confirm failure against the current delete branch.
- [ ] Remove only the hard-coded `deleteAppID` migration; retain stable mapped group ordering in `assignAppGroups` and all unrelated portal retry rules.
- [ ] Remove the deleted-operation R24 label and revise the expected retry-call count from nine to eight.
- [ ] Re-run release safety; commit `fix: remove destructive app group migration`.

### Task 4: Preserve the profile-only boundary

**Files:**
- Modify: `SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`
- Inspect: `Seal/Infrastructure/Signing/ApplePortalSigningService.swift:650-900`

- [ ] Write a failing policy test using a stored, reverse-order App Group entitlement record.
- [ ] Assert profile-only renewal preserves that authorization record and never selects a binary-signing plan.
- [ ] Run the focused test, add only the missing explicit policy assertion/API, and verify it passes.
- [ ] Do not sort legacy records and do not invoke the signer from renewal.
- [ ] Commit `test: preserve profile-only renewal boundary`.

### Task 5: Validate, document, and ship

**Files:**
- Modify: `DEBUG_LOG.md`

- [ ] Record that the previous patch targeted unused `upstream/SideSign`, while Seal compiles `Vendor/SideSign`; record removal of the App-ID deletion migration.
- [ ] Run:
  ```
  git diff --check
  python Scripts/verify-release-safety.py
  swift test --package-path Vendor/SideSign
  python -m unittest Scripts.tests.test_failure_contract_source -v
  ```
- [ ] Commit the audit entry.
- [ ] Push `perf/signing-renewal-speed` and monitor only the complete iOS workflow. Never run or inspect iOS Fast IPA.
- [ ] If CI fails because of the branch, add a focused regression test, fix the root cause, commit, push, and continue until the complete workflow is green.

