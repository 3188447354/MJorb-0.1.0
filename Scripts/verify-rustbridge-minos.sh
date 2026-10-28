#!/bin/bash
set -euo pipefail

FRAMEWORK_PATH="${1:-Vendor/Minimuxer/RustBridge/lib/RustBridge.xcframework}"
MAX_IOS_VERSION="${MAX_IOS_VERSION:-17.4}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "RustBridge minOS verification requires macOS/xcrun vtool." >&2
  exit 2
fi
if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find vtool >/dev/null 2>&1; then
  echo "xcrun vtool is required to inspect Mach-O deployment targets." >&2
  exit 2
fi
if [[ ! -d "$FRAMEWORK_PATH" ]]; then
  echo "RustBridge XCFramework not found: $FRAMEWORK_PATH" >&2
  exit 2
fi

version_gt() {
  python3 - "$1" "$2" <<'PY'
import sys

def parse(value):
    parts = value.split('.')
    nums = []
    for part in parts[:3]:
        try:
            nums.append(int(part))
        except ValueError:
            raise SystemExit(2)
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)

raise SystemExit(0 if parse(sys.argv[1]) > parse(sys.argv[2]) else 1)
PY
}

failures=0
checked=0
annotated=0
unannotated=0
unreadable=0
archives=0
device_archives=0
simulator_archives=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

while IFS= read -r archive; do
  archives=$((archives + 1))
  slice="$(basename "$(dirname "$archive")")"
  case "$slice" in
    ios-arm64)
      device_archives=$((device_archives + 1))
      slice_architectures=(arm64)
      ;;
    ios-arm64_x86_64-simulator)
      simulator_archives=$((simulator_archives + 1))
      slice_architectures=(arm64 x86_64)
      ;;
    *)
      echo "ERROR: unexpected non-iOS RustBridge slice: $slice" >&2
      failures=$((failures + 1))
      continue
      ;;
  esac

  case "$archive" in
    /*) archive_path="$archive" ;;
    *)  archive_path="$PWD/$archive" ;;
  esac

  for architecture in "${slice_architectures[@]}"; do
    arch_dir="$work/$slice-$architecture"
    mkdir -p "$arch_dir/objects"
    thin_archive="$arch_dir/librust_bridge.a"
    available_architectures="$(xcrun lipo -archs "$archive_path" 2>/dev/null || true)"
    if [[ "$available_architectures" == "$architecture" ]]; then
      # The device XCFramework slice is correctly a thin arm64 archive. `lipo -thin`
      # rejects thin input files, so copy that slice directly for object inspection.
      cp "$archive_path" "$thin_archive"
    elif ! xcrun lipo -thin "$architecture" "$archive_path" -output "$thin_archive" 2>/dev/null; then
      echo "ERROR: unable to extract $architecture from RustBridge slice $slice (available: $available_architectures)." >&2
      failures=$((failures + 1))
      continue
    fi
    (cd "$arch_dir/objects" && ar -x "$thin_archive")

    slice_checked=0
    slice_annotated=0
    slice_unannotated=0
    while IFS= read -r object; do
      checked=$((checked + 1))
      slice_checked=$((slice_checked + 1))
      if ! output="$(xcrun vtool -show-build "$object" 2>/dev/null)"; then
        echo "ERROR: unable to inspect $slice/$architecture/$(basename "$object")" >&2
        unreadable=$((unreadable + 1))
        failures=$((failures + 1))
        continue
      fi

      minos="$(printf '%s\n' "$output" | awk '/minos / { print $2; exit }')"
      if [[ -z "$minos" ]]; then
        # Rust's compiler_builtins/std runtime archives legitimately contain helper
        # objects without deployment metadata. Require at least one annotated object
        # per architecture while allowing those runtime helpers.
        unannotated=$((unannotated + 1))
        slice_unannotated=$((slice_unannotated + 1))
        continue
      fi

      annotated=$((annotated + 1))
      slice_annotated=$((slice_annotated + 1))
      if version_gt "$minos" "$MAX_IOS_VERSION"; then
        echo "ERROR: $slice/$architecture/$(basename "$object") requires iOS $minos (maximum allowed $MAX_IOS_VERSION)" >&2
        failures=$((failures + 1))
      fi
    done < <(find "$arch_dir/objects" -type f -name '*.o' -print)

    if (( slice_checked == 0 )); then
      echo "ERROR: no Mach-O objects found in RustBridge slice $slice ($architecture)." >&2
      failures=$((failures + 1))
    fi
    if (( slice_annotated == 0 )); then
      echo "ERROR: no deployment-target metadata found in RustBridge slice $slice ($architecture)." >&2
      failures=$((failures + 1))
    fi

    echo "RustBridge slice $slice ($architecture): checked=$slice_checked annotated=$slice_annotated unannotated-runtime-helpers=$slice_unannotated"
  done
done < <(
  for active_slice in ios-arm64 ios-arm64_x86_64-simulator; do
    archive="$FRAMEWORK_PATH/$active_slice/librust_bridge.a"
    [[ -f "$archive" ]] && printf '%s\n' "$archive"
  done
)

if (( checked == 0 )); then
  echo "ERROR: no RustBridge Mach-O objects were found." >&2
  exit 2
fi
if (( archives != 2 || device_archives != 1 || simulator_archives != 1 )); then
  echo "ERROR: RustBridge must contain arm64 device and universal arm64+x86_64 simulator slices (archives=$archives device=$device_archives simulator=$simulator_archives)." >&2
  failures=$((failures + 1))
fi

echo "Checked $checked RustBridge objects across $archives archives; annotated=$annotated unannotated-runtime-helpers=$unannotated unreadable=$unreadable failures=$failures"
(( failures == 0 ))
