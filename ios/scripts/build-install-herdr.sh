#!/bin/zsh
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IOS_DIR="${0:A:h:h}"
TEAM_ID="${COM_TEAM_ID:-AJN4TFSWT9}"
DEVICE_ID="${COM_DEVICE_ID:-00008160-001E3CEA36E00036}"
SIGN_IDENTITY="${HERDR_SIGN_IDENTITY:-5EE0A623BE1F6DE4E0F4981EE5F70E761C8364D6}"
CACHED_PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/6b58c0fb-a74f-4bf5-b713-9b05c077e4a4.mobileprovision"
ENTITLEMENTS="$HOME/AI_Work_System/work/sohu/狐小e-Duo适配/build_signed/entitlements.plist"

if [[ "${1:-}" == "--xcode-account" ]]; then
  echo "==> [Mode B] 使用 Xcode 在线账号自动申请 work.eddie.herdr 描述文件并编译签名..."
  xcodegen generate --spec "$IOS_DIR/project.yml" --project "$IOS_DIR"
  xcodebuild -skipPackagePluginValidation \
    -project "$IOS_DIR/Com.xcodeproj" \
    -scheme Herdr \
    -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$IOS_DIR/DerivedDataHerdr" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    build
  APP_PATH="$IOS_DIR/DerivedDataHerdr/Build/Products/Debug-iphoneos/Herdr.app"
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing work.eddie.herdr
  exit 0
fi

echo "==> [Mode A] 使用本机已缓存的有效描述文件 (AJN4TFSWT9, 有效期至 2026-11-13) 签名并安装 Herdr..."
RAW_APP="$IOS_DIR/DerivedDataHerdr/Build/Products/Debug-iphoneos/Herdr.app"
if [[ ! -d "$RAW_APP" ]]; then
  xcodebuild -skipPackagePluginValidation \
    -project "$IOS_DIR/Com.xcodeproj" \
    -scheme Herdr \
    -configuration Debug \
    -sdk iphoneos \
    -derivedDataPath "$IOS_DIR/DerivedDataHerdr" \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_DEBUG_DYLIB=NO \
    ENABLE_PREVIEWS=NO \
    build
  rm -f "$RAW_APP"/*.dylib(N)
fi

SIGNED_DIR="$IOS_DIR/DerivedDataHerdr/Signed"
SIGNED_APP="$SIGNED_DIR/Herdr.app"
rm -rf "$SIGNED_DIR"
mkdir -p "$SIGNED_DIR"
cp -R "$RAW_APP" "$SIGNED_APP"
cp -f "$CACHED_PROFILE" "$SIGNED_APP/embedded.mobileprovision"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier work.eddie.huxiaoe" "$SIGNED_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Herdr" "$SIGNED_APP/Info.plist"

for dylib in "$SIGNED_APP"/*.dylib(N); do
  codesign -f -s "$SIGN_IDENTITY" --timestamp=none "$dylib"
done

if [[ -d "$SIGNED_APP/Frameworks" ]]; then
  for f in "$SIGNED_APP/Frameworks"/*(N); do
    codesign -f -s "$SIGN_IDENTITY" --timestamp=none "$f"
  done
fi

codesign -f -s "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none "$SIGNED_APP"
codesign -vvv --deep --strict "$SIGNED_APP"

echo "==> 正在安装 Herdr.app 到 iPhone Duo ($DEVICE_ID)..."
xcrun devicectl device install app --device "$DEVICE_ID" "$SIGNED_APP"
echo "==> 正在冷启动 Herdr..."
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing work.eddie.huxiaoe
echo "==> Herdr 真机安装与冷启动完成！"
