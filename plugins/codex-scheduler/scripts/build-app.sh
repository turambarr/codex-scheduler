#!/bin/bash
# 构建 CodexScheduler.app：把 SwiftPM 可执行文件装进一个带 Info.plist 的 app 包里。
# 日历/提醒事项权限必须由 .app 包内的进程申请，裸二进制申请会被 TCC 拒绝。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

export CLANG_MODULE_CACHE_PATH="$ROOT/.cache/modules"
export TMPDIR="$ROOT/.cache/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

CONFIGURATION=${SCHEDULER_BUILD_CONFIGURATION:-release}
echo "==> 编译 ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --disable-sandbox --only-use-versions-from-resolved-file --cache-path "$ROOT/.cache/spm"

BIN=$(swift build -c "$CONFIGURATION" --disable-sandbox --cache-path "$ROOT/.cache/spm" --show-bin-path)/codex-scheduler
if [[ ! -x "$BIN" ]]; then
  echo "找不到可执行文件：$BIN" >&2
  exit 1
fi

APP="${SCHEDULER_APP_OUTPUT:-$ROOT/dist/CodexScheduler.app}"
APP_DIR=$(dirname "$APP")
mkdir -p "$APP_DIR"
STAGING=$(mktemp -d "$APP_DIR/.build-app.XXXXXX")
STAGED_APP="$STAGING/CodexScheduler.app"
echo "==> 组装 $APP"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN" "$STAGED_APP/Contents/MacOS/CodexScheduler"
cp "$ROOT/App/Info.plist" "$STAGED_APP/Contents/Info.plist"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"
# 某些环境（沙盒/同步盘）会给新文件打上 com.apple.provenance 等扩展属性，
# codesign 会因此报 “resource fork, Finder information, or similar detritus not allowed”。
xattr -cr "$STAGED_APP" 2>/dev/null || true

echo "==> 签名 (ad-hoc)"
ENT="$ROOT/App/CodexScheduler.entitlements"
codesign --force --sign - --identifier dev.codex.scheduler --timestamp=none \
  --entitlements "$ENT" "$STAGED_APP/Contents/MacOS/CodexScheduler"
codesign --force --sign - --identifier dev.codex.scheduler --timestamp=none \
  --entitlements "$ENT" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

PREVIOUS="$STAGING/Previous.app"
if [[ -e "$APP" ]]; then
  mv "$APP" "$PREVIOUS"
fi
if ! mv "$STAGED_APP" "$APP"; then
  if [[ -e "$PREVIOUS" ]]; then mv "$PREVIOUS" "$APP"; fi
  exit 1
fi
if [[ -e "$PREVIOUS" ]]; then
  echo "上一版保留在 $PREVIOUS"
else
  rmdir "$STAGING"
fi

echo "==> 完成：$APP"
echo
echo "下一步（只需一次）："
echo "  open -n -W -a \"$APP\" --args authorize"
echo "然后在弹出的系统对话框里点“允许”。"
echo
echo "（如果从终端直接运行 authorize，TCC 会把请求归因到终端/上层应用而拒绝弹窗；"
echo "  用 open 让 app 自己成为责任进程，并带上 App/CodexScheduler.entitlements。）"
