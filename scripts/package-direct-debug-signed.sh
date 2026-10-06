#!/usr/bin/env bash
#
# package-direct-debug-signed.sh — 生成可交付外部测试者的 Direct Debug DMG。
#
# 与 `package-direct-debug.sh` 的边界：
# - 仍使用 Debug configuration、独立 Debug bundle id 与测试 License API；
# - 先复用 `run-debug-direct.sh --build-only`，确保 Debug 菜单和渠道门禁一致；
# - 只在隔离副本上换成 Developer ID、Hardened Runtime 与安全时间戳；
# - 强制 notarization + staple，产物可由未登记设备上的 Gatekeeper 验证；
# - 不创建 tag、不生成 appcast、不上传官网，也不改写本机 Debug App。
#
# 用法：
#   scripts/package-direct-debug-signed.sh 1.9.0
#   STARCAT_NOTARY_PROFILE=starcat-notary \
#     scripts/package-direct-debug-signed.sh 1.9.0

set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须是 X.Y.Z，例如 1.9.0；当前: ${VERSION:-<empty>}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData-NoSandbox"
SOURCE_APP="$DERIVED_DATA/Build/Products/Debug/Starcat.app"
DIST_DIR="$PROJECT_ROOT/dist/direct-debug-signed"
WORK_DIR="$DIST_DIR/work"
STAGING_DIR="$DIST_DIR/staging"
DOWNLOADS_DIR="$DIST_DIR/downloads"
APP_PATH="$WORK_DIR/Starcat Debug.app"
DMG_PATH="$DOWNLOADS_DIR/Starcat-${VERSION}-debug-signed-arm64.dmg"
SHA_PATH="${DMG_PATH}.sha256"
NOTARY_OUTPUT_PATH="$DOWNLOADS_DIR/Starcat-${VERSION}-debug-signed-arm64.notary-submit.log"
NOTARY_SUBMISSION_PATH="$DOWNLOADS_DIR/Starcat-${VERSION}-debug-signed-arm64.notary-submission-id"
DIRECT_DISTRIBUTION_ENTITLEMENTS="$PROJECT_ROOT/Starcat/StarcatDirectDistribution.entitlements"
DIRECT_WIDGET_ENTITLEMENTS="$PROJECT_ROOT/Starcat/Resources/Widget/StarcatDirectWidgets.entitlements"
DEFAULT_SIGN_IDENTITY="Developer ID Application: liwen gong (8WCUMGCWMB)"
SIGN_IDENTITY="${STARCAT_DIRECT_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}}"
NOTARY_PROFILE="${STARCAT_NOTARY_PROFILE:-starcat-notary}"
BUILD_NUMBER="${STARCAT_DIRECT_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
DIRECT_DEBUG_BUNDLE_ID="com.starcat.app.direct.debug"
DIRECT_DEBUG_WIDGET_BUNDLE_ID="com.starcat.app.direct.debug.widgets"
LOCAL_AI_APP_GROUP="8WCUMGCWMB.com.starcat.app.localai"

log() { printf '[direct-debug-signed] %s\n' "$1"; }
fail() { printf '[direct-debug-signed] ERROR: %s\n' "$1" >&2; exit 1; }

if ! [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  fail "build number 必须是纯数字，当前: ${BUILD_NUMBER:-<empty>}"
fi
if [[ "$SIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  fail "外发 Debug 包必须使用 Developer ID Application，当前: $SIGN_IDENTITY"
fi
[ -n "$NOTARY_PROFILE" ] || fail "STARCAT_NOTARY_PROFILE 不能为空"

for command_name in codesign ditto hdiutil security shasum xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name 不在 PATH"
done
security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY" \
  || fail "Keychain 中未找到签名身份: $SIGN_IDENTITY"
[ -f "$DIRECT_DISTRIBUTION_ENTITLEMENTS" ] \
  || fail "缺少 Direct distribution entitlements: $DIRECT_DISTRIBUTION_ENTITLEMENTS"
[ -f "$DIRECT_WIDGET_ENTITLEMENTS" ] \
  || fail "缺少 Direct Widget entitlements: $DIRECT_WIDGET_ENTITLEMENTS"

cd "$PROJECT_ROOT"

log "构建 StarcatDirect Debug（build ${BUILD_NUMBER}）"
STARCAT_MARKETING_VERSION_OVERRIDE="$VERSION" \
STARCAT_DIRECT_BUILD_NUMBER="$BUILD_NUMBER" \
  bash "$SCRIPT_DIR/run-debug-direct.sh" --build-only

[ -d "$SOURCE_APP" ] || fail "未找到 Direct Debug App: $SOURCE_APP"

# 所有分发签名都在副本上完成。这样失败重试或公证诊断不会污染日常 `make run-direct`
# 使用的 DerivedData，也不会让 Apple Development 本机调试包失去原签名。
log "准备隔离签名副本"
rm -rf "$WORK_DIR" "$STAGING_DIR"
rm -f "$DMG_PATH" "$SHA_PATH" "$NOTARY_OUTPUT_PATH" "$NOTARY_SUBMISSION_PATH"
mkdir -p "$WORK_DIR" "$STAGING_DIR" "$DOWNLOADS_DIR"
ditto "$SOURCE_APP" "$APP_PATH"

APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Starcat"
SPARKLE_FRAMEWORK_PATH="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_CURRENT_PATH="$SPARKLE_FRAMEWORK_PATH/Versions/Current"
SWIFT_COMPATIBILITY_PATH="$APP_PATH/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/StarcatDirectWidgets.appex"
SAVER_PATH="$APP_PATH/Contents/Resources/StarcatScreensaver.saver"

[ -x "$APP_EXECUTABLE" ] || fail "Direct Debug 可执行文件不存在或不可执行"
[ -d "$SPARKLE_FRAMEWORK_PATH" ] || fail "Direct Debug 包缺少 Sparkle.framework"
[ -d "$WIDGET_PATH" ] || fail "Direct Debug 包缺少 StarcatDirectWidgets.appex"
[ -d "$SAVER_PATH" ] || fail "Direct Debug 包缺少 StarcatScreensaver.saver"

APP_VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$APP_VERSION" = "$VERSION" ] \
  || fail "CFBundleShortVersionString 应为 $VERSION，实际为 ${APP_VERSION:-<missing>}"

APP_BUILD=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$APP_BUILD" = "$BUILD_NUMBER" ] \
  || fail "CFBundleVersion 应为 $BUILD_NUMBER，实际为 ${APP_BUILD:-<missing>}"

BUNDLE_ID=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$BUNDLE_ID" = "$DIRECT_DEBUG_BUNDLE_ID" ] \
  || fail "Direct Debug bundle id 应为 $DIRECT_DEBUG_BUNDLE_ID，实际为 ${BUNDLE_ID:-<missing>}"

WIDGET_BUNDLE_ID=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleIdentifier' "$WIDGET_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$WIDGET_BUNDLE_ID" = "$DIRECT_DEBUG_WIDGET_BUNDLE_ID" ] \
  || fail "Direct Debug Widget bundle id 应为 $DIRECT_DEBUG_WIDGET_BUNDLE_ID，实际为 ${WIDGET_BUNDLE_ID:-<missing>}"

DIST_VALUE=$(/usr/libexec/PlistBuddy \
  -c 'Print :STARCAT_DISTRIBUTION' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$DIST_VALUE" = "direct" ] \
  || fail "STARCAT_DISTRIBUTION 应为 direct，实际为 ${DIST_VALUE:-<missing>}"

LICENSE_API_ENV=$(/usr/libexec/PlistBuddy \
  -c 'Print :STARCAT_LICENSE_API_ENVIRONMENT' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
[ "$LICENSE_API_ENV" = "test" ] \
  || fail "外发 Direct Debug 必须连接测试 License API，实际为 ${LICENSE_API_ENV:-<missing>}"

# 不能只相信 Debug configuration。直接检查实际 Mach-O，避免构建配置漂移后给测试者
# 发出没有 Debug 菜单的包。
grep -aFq "Who's Your Daddy" "$APP_EXECUTABLE" \
  || fail "Mach-O 中未找到 Debug 菜单，拒绝生成外发 DMG"

# Developer ID 分发包不能携带开发 provisioning profile。只删除隔离副本里的文件，
# 随后对所有可执行组件按内到外重签，避免外层资源封条绑定旧签名。
find "$APP_PATH" -type f -name embedded.provisionprofile -delete

SPARKLE_NESTED_CODE=(
  "$SPARKLE_CURRENT_PATH/XPCServices/Downloader.xpc"
  "$SPARKLE_CURRENT_PATH/XPCServices/Installer.xpc"
  "$SPARKLE_CURRENT_PATH/Updater.app"
  "$SPARKLE_CURRENT_PATH/Autoupdate"
)
for component_path in "${SPARKLE_NESTED_CODE[@]}"; do
  [ -e "$component_path" ] || fail "Sparkle.framework 缺少待签名组件: $component_path"
done

sign_nested_code() {
  local target_path="$1"
  # Sparkle helper 需要保留自身 identifier 与 entitlement，但不能保留旧的
  # Apple Development designated requirement。
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp \
    --preserve-metadata=identifier,entitlements "$target_path" >/dev/null
}

sign_distribution_code() {
  local target_path="$1"
  # 普通二进制不继承开发 entitlement，防止 get-task-allow 进入公证包。
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp \
    "$target_path" >/dev/null
}

sign_appex_code() {
  local target_path="$1"
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp \
    --entitlements "$DIRECT_WIDGET_ENTITLEMENTS" "$target_path" >/dev/null
}

sign_main_app() {
  codesign --force --options runtime --sign "$SIGN_IDENTITY" --timestamp \
    --entitlements "$DIRECT_DISTRIBUTION_ENTITLEMENTS" "$APP_PATH" >/dev/null
}

verify_developer_id_code() {
  local component_name="$1"
  local target_path="$2"
  local signature_output
  signature_output="$(codesign -dvvv "$target_path" 2>&1)"

  grep -q '^Authority=Developer ID Application:' <<<"$signature_output" \
    || fail "$component_name 未使用 Developer ID Application 签名"
  grep -q 'flags=.*runtime' <<<"$signature_output" \
    || fail "$component_name 未启用 Hardened Runtime"
  grep -q '^Timestamp=' <<<"$signature_output" \
    || fail "$component_name 缺少安全时间戳"
}

log "使用 Developer ID 重新签名 Debug 副本"
for component_path in "${SPARKLE_NESTED_CODE[@]}"; do
  sign_nested_code "$component_path"
done
sign_nested_code "$SPARKLE_FRAMEWORK_PATH"

if [ -f "$SWIFT_COMPATIBILITY_PATH" ]; then
  sign_distribution_code "$SWIFT_COMPATIBILITY_PATH"
fi
sign_appex_code "$WIDGET_PATH"
# ScreenSaver 是 MH_BUNDLE；与正式 Direct 一致，不传 entitlement，避免 macOS 工具链
# 静默丢弃 entitlement 后产生难以察觉的签名漂移。
sign_distribution_code "$SAVER_PATH"
sign_main_app

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
verify_developer_id_code "Starcat Debug.app" "$APP_PATH"
verify_developer_id_code "Sparkle.framework" "$SPARKLE_FRAMEWORK_PATH"
for component_path in "${SPARKLE_NESTED_CODE[@]}"; do
  verify_developer_id_code "$(basename "$component_path")" "$component_path"
done
if [ -f "$SWIFT_COMPATIBILITY_PATH" ]; then
  verify_developer_id_code "libswiftCompatibilitySpan.dylib" "$SWIFT_COMPATIBILITY_PATH"
fi
verify_developer_id_code "StarcatDirectWidgets.appex" "$WIDGET_PATH"
verify_developer_id_code "StarcatScreensaver.saver" "$SAVER_PATH"

FINAL_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
if grep -Eq 'com\.apple\.security\.(app-sandbox|get-task-allow)' <<<"$FINAL_ENTITLEMENTS"; then
  fail "主 App 最终签名仍包含 App Sandbox 或 get-task-allow entitlement"
fi
grep -Fq "$LOCAL_AI_APP_GROUP" <<<"$FINAL_ENTITLEMENTS" \
  || fail "主 App 最终签名缺少本地 AI 共享 App Group"

WIDGET_ENTITLEMENTS="$(codesign -d --entitlements :- "$WIDGET_PATH" 2>/dev/null || true)"
grep -q 'com.apple.security.app-sandbox' <<<"$WIDGET_ENTITLEMENTS" \
  || fail "Widget 缺少 app-sandbox entitlement"
if grep -Eq 'com\.apple\.security\.get-task-allow' <<<"$WIDGET_ENTITLEMENTS"; then
  fail "Widget 仍包含 get-task-allow entitlement"
fi
if grep -Fq "$LOCAL_AI_APP_GROUP" <<<"$WIDGET_ENTITLEMENTS"; then
  fail "Widget 不应获得本地 AI 共享 App Group"
fi
if find "$APP_PATH" -type f -name embedded.provisionprofile -print -quit | grep -q .; then
  fail "Developer ID 分发副本仍包含 embedded.provisionprofile"
fi

log "生成并签名外发 Debug DMG"
ditto "$APP_PATH" "$STAGING_DIR/Starcat Debug.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "Starcat ${VERSION} Debug" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null || fail "DMG 校验失败"

# DMG 是 Gatekeeper 首先检查的容器，必须先签名再提交公证；staple 后不能重签，
# 否则会改变容器并使 Apple 票据失效。
DMG_SIGN_OK=0
for sign_attempt in 1 2 3 4 5; do
  if codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH" >/dev/null \
    && codesign --verify --verbose=2 "$DMG_PATH"; then
    DMG_SIGN_OK=1
    break
  fi
  log "DMG 签名或校验失败，重试 ${sign_attempt}/5"
  sleep 3
done
[ "$DMG_SIGN_OK" = "1" ] || fail "DMG 容器签名失败（含安全时间戳）"

log "提交 Apple notarization（profile: ${NOTARY_PROFILE}）"
set +e
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait 2>&1 | tee "$NOTARY_OUTPUT_PATH"
NOTARY_EXIT=${PIPESTATUS[0]}
set -e

SUBMISSION_ID="$(sed -n 's/^[[:space:]]*id:[[:space:]]*//p' "$NOTARY_OUTPUT_PATH" | head -1)"
if [ -n "$SUBMISSION_ID" ]; then
  printf '%s\n' "$SUBMISSION_ID" >"$NOTARY_SUBMISSION_PATH"
  log "notarization submission id: $SUBMISSION_ID"
fi
if [ "$NOTARY_EXIT" -ne 0 ]; then
  fail "notarization 提交或等待失败，完整输出: $NOTARY_OUTPUT_PATH"
fi
grep -Eq 'status:[[:space:]]*Accepted' "$NOTARY_OUTPUT_PATH" \
  || fail "notarization 未返回 Accepted，完整输出: $NOTARY_OUTPUT_PATH"

log "装订并验证 Apple 公证票据"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null || fail "staple 后 DMG 校验失败"

# stapler 会写入 DMG，最终 SHA 必须在装订票据之后计算。
(
  cd "$DOWNLOADS_DIR"
  shasum -a 256 "$(basename "$DMG_PATH")" >"$(basename "$SHA_PATH")"
  shasum -a 256 -c "$(basename "$SHA_PATH")"
)

# 最后从只读挂载的实际交付物复核，而不是只检查打包前 staging 副本。
MOUNT_POINT="$(mktemp -d /tmp/starcat-direct-debug-signed-mount.XXXXXX)"
DMG_ATTACHED=0
cleanup_mount() {
  if [ "$DMG_ATTACHED" -eq 1 ]; then
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup_mount EXIT

hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=1
MOUNTED_APP="$MOUNT_POINT/Starcat Debug.app"
[ -d "$MOUNTED_APP" ] || fail "DMG 中缺少 Starcat Debug.app"
codesign --verify --deep --strict "$MOUNTED_APP" \
  || fail "DMG 内 App 签名校验失败"
spctl --assess --type execute --verbose=4 "$MOUNTED_APP" \
  || fail "DMG 内 App 未通过 Gatekeeper"

MOUNTED_VERSION=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' "$MOUNTED_APP/Contents/Info.plist" 2>/dev/null || true)
[ "$MOUNTED_VERSION" = "$VERSION" ] \
  || fail "DMG 内 App 版本应为 $VERSION，实际为 ${MOUNTED_VERSION:-<missing>}"

hdiutil detach "$MOUNT_POINT" >/dev/null
DMG_ATTACHED=0
rmdir "$MOUNT_POINT"
trap - EXIT

rm -rf "$WORK_DIR" "$STAGING_DIR"

log "外发 Direct Debug 包生成成功"
echo "    DMG: $DMG_PATH"
echo "    SHA: $SHA_PATH"
echo "    version: $VERSION"
echo "    build: $BUILD_NUMBER"
echo "    bundle id: $DIRECT_DEBUG_BUNDLE_ID"
echo "    license api: test"
echo "    signing: $SIGN_IDENTITY"
echo "    notarization: Accepted and stapled"

