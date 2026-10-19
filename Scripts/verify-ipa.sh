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
#
# ⚠️ 两个必须写对的地方（2026-10-16 两轮实测各踩一个）：
#   ① `unzip -Z1` 会把**目录本身**也列为条目 ⇒ 要放行 `PlugIns/` 这一级，
#      否则报 `Unexpected app extension in Seal IPA: Payload/Seal.app/PlugIns/`，
#      那是守卫自己的误报。
#   ② 放行 `PlugIns/` **只能是精确匹配那一条目录条目**，不能当成前缀 ——
#      写成前缀会把 `PlugIns/Evil.appex/…` 一起放进来，让守卫比原来更弱。
allowed_exact=(
  "Payload/Seal.app/PlugIns/"
  "Payload/Seal.app/PlugIns/SealLiveActivity.appex/"
)
allowed_prefix="Payload/Seal.app/PlugIns/SealLiveActivity.appex/"
if grep -q '^Payload/Seal\.app/PlugIns/' <<<"$entries"; then
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    allowed=0
    for exact in "${allowed_exact[@]}"; do
      [[ "$entry" == "$exact" ]] && { allowed=1; break; }
    done
    if [[ "$allowed" -ne 1 && "$entry" == "$allowed_prefix"* ]]; then
      allowed=1
    fi
    if [[ "$allowed" -ne 1 ]]; then
      echo "Unexpected app extension in Seal IPA: $entry (only SealLiveActivity is allowed)" >&2
      exit 1
    fi
  done < <(grep '^Payload/Seal\.app/PlugIns/' <<<"$entries")
  # 白名单命中了目录，但目录里必须真有可执行文件 —— 空壳 appex 装得上却永远不会显示。
  if ! grep -q '^Payload/Seal\.app/PlugIns/SealLiveActivity\.appex/[^/]\+$' <<<"$entries"; then
    echo "SealLiveActivity.appex is present but contains no executable" >&2
    exit 1
  fi
  if ! grep -Fxq "Payload/Seal.app/PlugIns/SealLiveActivity.appex/Assets.car" <<<"$entries"; then
    echo "SealLiveActivity.appex is missing its compiled asset catalog" >&2
    exit 1
  fi
  if grep -q '^Payload/Seal\.app/PlugIns/SealLiveActivity\.appex/' <<<"$entries"; then
    if ! grep -Fxq "Payload/Seal.app/PlugIns/SealLiveActivity.appex/Info.plist" <<<"$entries"; then
      echo "SealLiveActivity.appex is missing Info.plist" >&2
      exit 1
    fi
    info_dir="$(mktemp -d)"
    trap 'rm -rf "$info_dir"' EXIT
    unzip -p "$ipa" Payload/Seal.app/Info.plist > "$info_dir/main.plist"
    unzip -p "$ipa" Payload/Seal.app/PlugIns/SealLiveActivity.appex/Info.plist > "$info_dir/activity.plist"
    main_version="$(plutil -extract CFBundleShortVersionString raw "$info_dir/main.plist")"
    activity_version="$(plutil -extract CFBundleShortVersionString raw "$info_dir/activity.plist")"
    main_build="$(plutil -extract CFBundleVersion raw "$info_dir/main.plist")"
    activity_build="$(plutil -extract CFBundleVersion raw "$info_dir/activity.plist")"
    if [[ "$main_version" != "$activity_version" || "$main_build" != "$activity_build" ]]; then
      echo "Seal and SealLiveActivity versions must match (main: $main_version/$main_build; extension: $activity_version/$activity_build)" >&2
      exit 1
    fi
  fi
fi
if grep -Eqi '\.(p12|mobileprovision)$|PairingFile\.plist$|Auth\.json$' <<<"$entries"; then
  echo "Sensitive signing material found in IPA" >&2
  exit 1
fi

unzip -p "$ipa" Payload/Seal.app/Info.plist > build/Seal-Info.plist
plutil -lint build/Seal-Info.plist

echo "Unsigned IPA verification passed (extensions limited to the SealLiveActivity widget)."
