#!/bin/zsh
set -euo pipefail
IOS_DIR="${0:A:h:h}"
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/com-live.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name ComCore "$IOS_DIR"/Com/Core/*.swift -o "$CHECK_DIR/libComCore.dylib" -emit-module-path "$CHECK_DIR/ComCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lComCore -Xlinker -rpath -Xlinker "$CHECK_DIR" "$IOS_DIR/Scripts/LiveProbe.swift" -o "$CHECK_DIR/check-live"
"$CHECK_DIR/check-live" "${1:-https://pi.eddiegao.work:8443/sessions}"
