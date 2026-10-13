#!/usr/bin/env bash
set -euo pipefail

ipa="${1:-build/Seal.ipa}"
entries="$(unzip -Z1 "$ipa")"

grep -q '^Payload/Seal.app/Info.plist$' <<<"$entries"
for library in libCoreADI.so libstoreservicescore.so; do
  if ! grep -Fxq "Payload/Seal.app/Anisette/$library" <<<"$entries"; then
    echo "::error::Required Anisette library is missing from IPA: $library" >&2
    exit 1
  fi
done
if grep -q '^Payload/Seal.app/PlugIns/' <<<"$entries"; then
  echo "Unexpected app extension found in Seal IPA (no-extension build expected)" >&2
  exit 1
fi
if grep -Eqi '\.(p12|mobileprovision)$|PairingFile\.plist$|Auth\.json$' <<<"$entries"; then
  echo "Sensitive signing material found in IPA" >&2
  exit 1
fi

unzip -p "$ipa" Payload/Seal.app/Info.plist > build/Seal-Info.plist
plutil -lint build/Seal-Info.plist

echo "Unsigned IPA verification passed (no embedded extension)."
