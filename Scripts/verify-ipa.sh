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
# 嵌入式扩展：**白名单**，不是「一律不许」。
#
# 历史上这里是一刀切禁止 `PlugIns/`（"no-extension build expected"），因为当时
# 确实没有任何扩展。2026-10-16 起 Seal 有一个**明确需要**的扩展：配对码的
# Live Activity —— 配对码要输进系统设置，进设置就得离开 Seal，镜像到灵动岛后
# 输码时一直看得见、点一下还能跳回 Seal。
#
# 直接把守卫删掉会丢掉它真正要保的东西：「别让任意/意外的扩展混进发布包」。
# 所以改成白名单 —— **只认这一个扩展**，任何别的 `.appex` 仍然拒收。
allowed_extension="Payload/Seal.app/PlugIns/SealLiveActivity.appex/"
if grep -q '^Payload/Seal\.app/PlugIns/' <<<"$entries"; then
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    case "$entry" in
      "$allowed_extension"*) ;;
      *)
        echo "Unexpected app extension in Seal IPA: $entry (only SealLiveActivity is allowed)" >&2
        exit 1
        ;;
    esac
  done < <(grep '^Payload/Seal\.app/PlugIns/' <<<"$entries")
  # 白名单命中了目录，但目录里必须真有可执行文件，否则是空壳扩展（装上也永远不会显示）。
  if ! grep -q "^${allowed_extension}[^/]\+$" <<<"$entries"; then
    echo "SealLiveActivity.appex is present but contains no executable" >&2
    exit 1
  fi
fi
if grep -Eqi '\.(p12|mobileprovision)$|PairingFile\.plist$|Auth\.json$' <<<"$entries"; then
  echo "Sensitive signing material found in IPA" >&2
  exit 1
fi

unzip -p "$ipa" Payload/Seal.app/Info.plist > build/Seal-Info.plist
plutil -lint build/Seal-Info.plist

echo "Unsigned IPA verification passed (extensions limited to the SealLiveActivity widget)."
