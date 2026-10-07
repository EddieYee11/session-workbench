#!/bin/zsh
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IOS_DIR="${0:A:h:h}"
COM_SIMULATOR_ID="${1:-}"
if [[ -z "$COM_SIMULATOR_ID" ]]; then
  COM_SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; data=json.load(sys.stdin); rows=[d for r,ds in data["devices"].items() if "iOS-26" in r or "iOS-27" in r for d in ds if d["isAvailable"] and "iPhone" in d["name"]]; rows.sort(key=lambda d: d["name"]!="iPhone 17 Pro"); print(rows[0]["udid"] if rows else "")')
fi
if [[ -z "$COM_SIMULATOR_ID" ]]; then
  print -u2 '没有可用的 iOS 26 或更高 iPhone 模拟器，请在 Xcode 下载运行时。'
  exit 2
fi
xcodegen generate --spec "$IOS_DIR/project.yml" --project "$IOS_DIR"
xcodebuild -skipPackagePluginValidation -project "$IOS_DIR/Com.xcodeproj" -scheme Com -destination "platform=iOS Simulator,id=$COM_SIMULATOR_ID" -derivedDataPath "$IOS_DIR/DerivedData" CODE_SIGNING_ALLOWED=NO test
