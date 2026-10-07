#!/bin/zsh
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IOS_DIR="${0:A:h:h}"
COM_TEAM_ID="${1:?用法: build-install.sh PERSONAL_TEAM_ID DEVICE_UDID}"
COM_DEVICE_ID="${2:?请提供 iPhone UDID}"
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  print -u2 '当前没有选中完整 Xcode。先安装并在 Xcode 登录 Apple 账号。'
  exit 2
fi
if [[ ! "$COM_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]]; then
  print -u2 'Personal Team ID 应为 10 位大写字母和数字。'
  exit 2
fi
print "DEVELOPMENT_TEAM = $COM_TEAM_ID" > "$IOS_DIR/Signing.xcconfig"
xcodegen generate --spec "$IOS_DIR/project.yml" --project "$IOS_DIR"
xcodebuild -skipPackagePluginValidation -project "$IOS_DIR/Com.xcodeproj" -scheme Com -configuration Debug -destination "id=$COM_DEVICE_ID" -derivedDataPath "$IOS_DIR/DerivedData" -allowProvisioningUpdates DEVELOPMENT_TEAM="$COM_TEAM_ID" build
APP_PATH="$IOS_DIR/DerivedData/Build/Products/Debug-iphoneos/Com.app"
xcrun devicectl device install app --device "$COM_DEVICE_ID" "$APP_PATH"
xcrun devicectl device process launch --device "$COM_DEVICE_ID" --terminate-existing work.eddie.com
