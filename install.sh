#!/bin/bash
# 把结界装到 ~/Library（程序不放桌面，避免启动时触发桌面权限弹窗）并编译界面
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"; dst="$HOME/Library/Application Support/Kekkai/bin"
mkdir -p "$dst"; cp "$src/kekkai" "$dst/kekkai";
clang -dynamiclib -fobjc-arc -Wno-deprecated-declarations -arch arm64 -arch x86_64 -framework Foundation -framework CoreLocation "$src/Sources/fakeloc.m" -o "$dst/libfakeloc.dylib"
clang -dynamiclib -arch arm64 -arch x86_64 "$src/Sources/fakeuser.c" -o "$dst/libkekkaiuser.dylib"; rm -rf "$dst/rules"; cp -R "$src/rules" "$dst/rules"
app="$HOME/Applications/Kekkai.app"; rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library -o "$app/Contents/MacOS/Kekkai" "$src/Sources/Kekkai.swift"
cp "$src/Info.plist" "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"; cp "$src/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
for l in en zh-Hans; do mkdir -p "$app/Contents/Resources/$l.lproj"; done
printf 'CFBundleName = "Kekkai";\nCFBundleDisplayName = "Kekkai";\n' > "$app/Contents/Resources/en.lproj/InfoPlist.strings"
printf 'CFBundleName = "结界";\nCFBundleDisplayName = "结界";\n' > "$app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
codesign -f -s - "$app"; echo "Installed / 已安装：$app"
