#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$repo_root/build/Seal 更新包"
notes_file="$repo_root/RELEASE_NOTES.md"
upload_url="https://seal.mjorb.eu.cc/uploads.php?action=upload"

if [[ $# -gt 1 ]]; then
  echo "用法：bash Scripts/upload-seal-update.sh [Seal IPA 路径]" >&2
  exit 2
fi

version="$(sed -n '1s/^# *//p' "$notes_file")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "无法从 RELEASE_NOTES.md 第一行读取三段版本号。" >&2
  exit 1
fi

message="$(awk 'NR == 1 { next } /^# / { exit } /^- / { sub(/^- /, ""); if (count++) printf "\n"; printf "%s", $0 }' "$notes_file")"
if [[ -z "$message" ]]; then
  echo "RELEASE_NOTES.md 中没有找到本版本更新内容。" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  ipa_path="$1"
else
  shopt -s nullglob
  ipa_candidates=("$release_dir"/Seal-*.ipa)
  if [[ ${#ipa_candidates[@]} -eq 1 ]]; then
    ipa_path="${ipa_candidates[0]}"
  elif [[ ${#ipa_candidates[@]} -gt 1 ]]; then
    echo "更新包文件夹里有多个 IPA，请先只保留要上传的版本，或把 IPA 路径作为参数传入。" >&2
    exit 1
  elif [[ -f "$repo_root/build/Seal_${version}.ipa" ]]; then
    ipa_path="$repo_root/build/Seal_${version}.ipa"
  else
    echo "找不到 Seal $version 的 IPA。请先构建并放入“build/Seal 更新包”。" >&2
    exit 1
  fi
fi

if [[ ! -f "$ipa_path" ]]; then
  echo "找不到 IPA：$ipa_path" >&2
  exit 1
fi

ipa_name="$(basename "$ipa_path")"
case "$ipa_name" in
  "Seal-${version}-"*.ipa|"Seal_${version}.ipa") ;;
  *)
    echo "IPA 文件名与更新说明版本不一致：当前说明是 $version，文件是 $ipa_name。" >&2
    exit 1
    ;;
esac

if ! unzip -tq "$ipa_path" >/dev/null; then
  echo "IPA 压缩包校验失败，已停止上传。" >&2
  exit 1
fi

upload_password="${SEAL_UPLOAD_PASSWORD:-}"
if [[ -z "$upload_password" ]]; then
  if [[ ! -r /dev/tty ]]; then
    echo "请在交互式终端运行，或设置 SEAL_UPLOAD_PASSWORD。" >&2
    exit 1
  fi
  printf "输入服务器上传口令（输入时不显示）： " >&2
  IFS= read -r -s upload_password </dev/tty
  printf "\n" >&2
fi
if [[ -z "$upload_password" || "$upload_password" == *$'\n'* || "$upload_password" == *$'\r'* ]]; then
  echo "上传口令为空或格式无效。" >&2
  exit 1
fi

# Feed the secret to curl through its config stdin so it is not stored in shell
# history or exposed as a curl command-line argument.
escaped_password="${upload_password//\\/\\\\}"
escaped_password="${escaped_password//\"/\\\"}"
unset upload_password

echo "正在上传 Seal ${version}：${ipa_name}"
if ! response="$(
  printf 'header = "X-Upload-Password: %s"\n' "$escaped_password" |
    curl --fail-with-body --show-error --silent --config - \
      --connect-timeout 30 --max-time 1800 --retry 2 \
      --form "ipa=@${ipa_path};type=application/octet-stream" \
      --form-string "version=$version" \
      --form-string "title=Seal $version" \
      --form-string "message=$message" \
      "$upload_url"
)"; then
  [[ -n "$response" ]] && printf '%s\n' "$response" >&2
  exit 1
fi

printf '%s' "$response" | /usr/bin/python3 -c '
import json
import sys

try:
    result = json.load(sys.stdin)
except Exception as error:
    print(f"服务器返回的内容不是有效 JSON：{error}", file=sys.stderr)
    sys.exit(1)

if not result.get("ok"):
    print(result.get("message", "上传失败。"), file=sys.stderr)
    sys.exit(1)

latest = result.get("latest", {})
print(result.get("message", "上传成功。"))
print("版本：" + str(latest.get("version", "未知")))
print("下载地址：" + str(latest.get("download_url", "未知")))
print("校验文件：" + str(latest.get("sha256_url", "未知")))
'
