#!/bin/zsh
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IOS_DIR="${0:A:h:h}"
DEVICE_ID="${COM_DEVICE_ID:-00008160-001E3CEA36E00036}"
ALLSIGN_BUNDLE="signall.nuosike.sign"
WORK_DIR="/tmp/com-allsign-pack"
DERIVED_DIR="/tmp/com-allsign-derived"

echo "==> 1. 生成 Com.xcodeproj 并编译真机无签名包 (iphoneos)..."
cd "$IOS_DIR"
xcodegen generate --spec "$IOS_DIR/project.yml" --project "$IOS_DIR"
xcodebuild -skipPackagePluginValidation \
  -project "$IOS_DIR/Com.xcodeproj" \
  -scheme Com \
  -configuration Debug \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_DEBUG_DYLIB=NO \
  ENABLE_PREVIEWS=NO \
  build | tail -n 10

RAW_APP="$DERIVED_DIR/Build/Products/Debug-iphoneos/Com.app"
if [[ ! -d "$RAW_APP" ]]; then
  echo "ERROR: 未找到编译产物 $RAW_APP" >&2
  exit 1
fi

echo "==> 2. 清理 PlugIns / 调试 dylib / 临时备份并打包 Com.ipa..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/Payload"
cp -R "$RAW_APP" "$WORK_DIR/Payload/Com.app"
rm -rf "$WORK_DIR/Payload/Com.app/PlugIns"
rm -rf "$WORK_DIR/Payload/Com.app/_CodeSignature"
rm -f "$WORK_DIR/Payload/Com.app"/*.dylib(N)
rm -f "$WORK_DIR/Payload/Com.app"/*.bak*(N)

BUILD_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$WORK_DIR/Payload/Com.app/Info.plist")
SHORT_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK_DIR/Payload/Com.app/Info.plist")

cd "$WORK_DIR"
zip -qry "$WORK_DIR/Com.ipa" Payload
IPA_SIZE=$(stat -f%z "$WORK_DIR/Com.ipa")
echo "    Com.ipa 打包完成: 版本 $SHORT_VER ($BUILD_VER), 大小 $IPA_SIZE 字节"

echo "==> 3. 推送 Com.ipa 到 iPhone ($DEVICE_ID) 全能签 ($ALLSIGN_BUNDLE)..."
xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$ALLSIGN_BUNDLE" \
  --source "$WORK_DIR/Com.ipa" \
  --destination "Documents/AllInSign/Resources/IPA/Com.ipa"

xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$ALLSIGN_BUNDLE" \
  --source "$WORK_DIR/Com.ipa" \
  --destination "Documents/Inbox/Com.ipa"

echo "==> 4. 同步更新全能签 index.json 元数据..."
mkdir -p "$WORK_DIR/DB"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$ALLSIGN_BUNDLE" \
  --source "Library/Application Support/AllInSign/DB/index.json" \
  --destination "$WORK_DIR/DB/index.json"

python3 - "$WORK_DIR/DB/index.json" "$BUILD_VER" "$SHORT_VER" "$IPA_SIZE" << 'PY'
import datetime, json, sys
path, build_ver, short_ver, ipa_size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
files = data.get("files", [])
updated = False
for item in files:
    if item.get("category") == "ipa" and item.get("bundleId") == "work.eddie.com":
        item["displayName"] = f"Com ({build_ver})"
        item["build"] = build_ver
        item["version"] = short_ver
        item["sizeBytes"] = ipa_size
        item["createdAt"] = now_iso
        item["relativePath"] = "/Resources/IPA/Com.ipa"
        item["originalFilename"] = "Com.ipa"
        updated = True
if not updated:
    files.insert(0, {
        "fileId": f"be71195c-8776-4d7e-8c3b-{build_ver}",
        "category": "ipa",
        "displayName": f"Com ({build_ver})",
        "iconRelativePath": "/Resources/Icons/be71195c-8776-4d7e-8c3b-a7a3acbb893b.png",
        "build": build_ver,
        "sizeBytes": ipa_size,
        "bundleId": "work.eddie.com",
        "version": short_ver,
        "relativePath": "/Resources/IPA/Com.ipa",
        "createdAt": now_iso,
        "originalFilename": "Com.ipa",
    })
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY

xcrun devicectl device copy to \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$ALLSIGN_BUNDLE" \
  --source "$WORK_DIR/DB/index.json" \
  --destination "Library/Application Support/AllInSign/DB/index.json"

echo "==> 5. 重启手机上的全能签以刷新列表..."
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$ALLSIGN_BUNDLE"
rm -rf "$WORK_DIR" "$DERIVED_DIR"
echo "==> 完成！请在手机全能签「应用/资源」里点 Com ($BUILD_VER) 签名并安装。"
