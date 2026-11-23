#!/bin/bash
# ArgusLid 一键安装 / 升级
#   curl -fsSL https://raw.githubusercontent.com/GZhengHao/argus-lid/main/install.sh | bash
#
# 做了什么：从 GitHub Releases 下载最新版 → 校验 SHA-256 → 放进 /Applications → 启动。
# 用 curl 下载的文件不带「来自网络」的隔离标记，所以首次打开不会被 Gatekeeper 拦截。
set -euo pipefail

REPO="GZhengHao/argus-lid"
APP_NAME="ArgusLid"
BASE="${ARGUSLID_BASE:-https://github.com/$REPO/releases/latest/download}"   # 覆盖仅供测试
DEST="${ARGUSLID_DEST:-/Applications}"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$*"; }
die()  { printf "\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "ArgusLid only runs on macOS."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( MAJOR >= 26 )) || die "ArgusLid needs macOS 26 or later (you have $(sw_vers -productVersion))."

bold "Installing $APP_NAME…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE/$APP_NAME.zip" -o "$TMP/$APP_NAME.zip" || die "Download failed."
curl -fsSL "$BASE/$APP_NAME.zip.sha256" -o "$TMP/sum" || die "Checksum download failed."
EXPECTED=$(awk '{print $1}' "$TMP/sum")
ACTUAL=$(shasum -a 256 "$TMP/$APP_NAME.zip" | awk '{print $1}')
[[ "$EXPECTED" == "$ACTUAL" ]] || die "Checksum mismatch, aborting."
ok "Downloaded and verified"

ditto -x -k "$TMP/$APP_NAME.zip" "$TMP/x"
[[ -d "$TMP/x/$APP_NAME.app" ]] || die "Archive did not contain $APP_NAME.app."

# 退出正在运行的旧版本（不会改动睡眠设置，新版本启动后会接管）
if pgrep -xq "$APP_NAME"; then
  pkill -x "$APP_NAME" || true
  sleep 1
fi

SUDO=""
[[ -w "$DEST" ]] || SUDO="sudo"
$SUDO rm -rf "$DEST/$APP_NAME.app"
$SUDO ditto "$TMP/x/$APP_NAME.app" "$DEST/$APP_NAME.app"
$SUDO xattr -dr com.apple.quarantine "$DEST/$APP_NAME.app" 2>/dev/null || true
ok "Installed to $DEST/$APP_NAME.app"

for old in Argus LidAwake; do
  [[ -d "$DEST/$old.app" ]] && printf "  note: an older version is still at %s — you can move it to the Trash.\n" "$DEST/$old.app"
done

open "$DEST/$APP_NAME.app"
ok "Launched. Look for the 👁 icon in the menu bar."
