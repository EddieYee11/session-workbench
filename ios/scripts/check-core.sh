#!/bin/zsh
set -euo pipefail
IOS_DIR="${0:A:h:h}"
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/com-core.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library -emit-library -emit-module -module-name ComCore "$IOS_DIR"/Com/Core/*.swift -o "$CHECK_DIR/libComCore.dylib" -emit-module-path "$CHECK_DIR/ComCore.swiftmodule"
swiftc -swift-version 6 -parse-as-library -I "$CHECK_DIR" -L "$CHECK_DIR" -lComCore -Xlinker -rpath -Xlinker "$CHECK_DIR" "$IOS_DIR/Tests/Core/Checks.swift" "$IOS_DIR/Scripts/CoreRunner.swift" -o "$CHECK_DIR/check-core"
"$CHECK_DIR/check-core"
