#!/bin/zsh
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
print 'macOS'
sw_vers -productVersion
print 'Developer directory'
print "$DEVELOPER_DIR"
print 'Signing identities'
security find-identity -v -p codesigning
if command -v idevice_id >/dev/null; then
  print 'Connected iPhones'
  idevice_id -l
fi
if [[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  xcodebuild -version
  xcrun devicectl list devices
  xcrun simctl list devices available
fi
