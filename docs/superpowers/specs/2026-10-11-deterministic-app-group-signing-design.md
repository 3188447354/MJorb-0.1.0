# Deterministic App Group Signing Design

## Goal

Make every full Seal signing path produce deterministic App Group entitlement
order without deleting an Apple App ID. Preserve the safety boundary of
profile-only renewal: it renews profiles only and never claims to repair an
already-signed binary.

## Evidence

- The Xcode project consumes `Vendor/SideSign`, not `upstream/SideSign`.
- The prior ordering patch exists only in `upstream/SideSign`, so it is absent
  from the shipped signing path.
- `AppBundleSigner.prepare` is invoked once for the main app and every app
  extension. It is the single point where profile entitlements become signed
  binary entitlements.
- `prepareProfileOnlyRenewal` injects a new profile without invoking
  `AppBundleSigner`; it cannot repair binary entitlement order.
- Apple documents that deleting an App ID invalidates provisioning profiles
  containing it. Deleting an ID is therefore not a normal migration tool.

## Scope

### Full signing paths

The following paths all use `SideSignAppSigner` and must obtain identical
entitlement behavior:

1. First signing of an imported IPA.
2. Signing a pending overwrite update.
3. Signing Seal's own replacement IPA.
4. Retrying a full signing transaction.
5. Every nested app extension included in those IPA files.

### Profile-only renewal

This path keeps its current contract: request and inject a fresh profile for
the existing signing identity. It does not rewrite the IPA or alter its signed
entitlements. A profile-only renewal is therefore not presented as an App
Group repair. A user who needs an older binary repaired must complete one full
signing transaction.

## Design

### Canonicalization boundary

Add a single internal canonicalizer to the *vendored* SideSign signer. It
accepts the profile entitlement dictionary, recognizes only
`com.apple.security.application-groups`, and replaces a valid array of strings
with a lexicographically sorted, de-duplicated array. Invalid or mixed-type
arrays are retained unchanged; the existing entitlement/profile validation
remains responsible for rejecting unsupported input.

No other entitlement arrays are reordered. In particular, keychain access
groups are deliberately untouched because their first item can carry default
access-group semantics.

The canonicalizer runs immediately before the entitlement plist is serialized
for each `AppBundle`. Consequently main apps and extensions receive the same
rule, independent of Apple portal response order and independent of the
original IPA's order.

### Apple portal behavior

`ApplePortalSigningService` continues to map and request App Groups in stable
order for new App IDs. This is a best-effort portal hygiene rule only; the
binary canonicalizer is the correctness boundary. Remove the hard-coded,
one-time LiveContainer2 App ID deletion branch and its release-safety anchor.
No normal signing action may delete an App ID solely to influence list order.

### Historical migration

Records already installed with an old reversed binary entitlement remain
unchanged by profile-only renewal, by design. The next full signing operation
produces canonical entitlements. The operation's existing distinction between
profile-only renewal and complete signing is kept explicit in user-facing
progress and failure recovery; no silent claim of repair is allowed.

## Verification

1. Unit-test canonicalization for `[AltStore, SideStore]`, the inverse order,
   duplicates, a singleton, and a non-string array.
2. Test the real `AppBundleSigner` preparation path with a main bundle and an
   extension whose profiles declare the same groups in opposite orders; both
   emitted entitlement plists must be canonical and equal.
3. Test that keychain access-group order is unchanged.
4. Test that profile-only renewal remains profile-only and has no dependency on
   the canonicalizer.
5. Run the focused signer and renewal suites, release-safety guards, then the
   complete iOS workflow. Do not trigger iOS Fast IPA.

## Non-goals

- Circumventing Apple entitlement or provisioning restrictions.
- Reordering entitlement arrays with documented order semantics.
- Deleting or recreating unrelated portal resources.
