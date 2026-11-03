#!/bin/bash
# 编译出自包含的 build/Kekkai.app：界面、命令行、注入库和规则都在包里，
# 第一次打开（或版本变化）时由 App 自己装到 ~/Library/Application Support/Kekkai/bin
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
app="$src/build/Kekkai.app"; res="$app/Contents/Resources"; sup="$res/support"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$sup"
swiftc -O -parse-as-library -o "$app/Contents/MacOS/Kekkai" "$src/Sources/Kekkai.swift"
clang -dynamiclib -fobjc-arc -Wno-deprecated-declarations -arch arm64 -arch x86_64 -framework Foundation -framework CoreLocation \
  "$src/Sources/fakeloc.m" -o "$sup/libfakeloc.dylib"
clang -dynamiclib -arch arm64 -arch x86_64 -framework CoreFoundation -framework IOKit -framework SystemConfiguration -framework DiskArbitration -framework CoreGraphics -framework ColorSync -framework Network -lobjc \
  "$src/Sources/inject.c" -o "$sup/libkekkai.dylib"
cp "$src/kekkai" "$sup/kekkai"; cp -R "$src/rules" "$sup/rules"
# 内容变了才重装支持文件：用支持文件本身的哈希作版本
(cd "$sup" && find . -type f ! -name build-id -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16) > "$sup/build-id"
cp "$src/Info.plist" "$app/Contents/Info.plist"
cp "$src/Assets/AppIcon.icns" "$res/AppIcon.icns"
for l in en zh-Hans; do mkdir -p "$res/$l.lproj"; done
printf 'CFBundleName = "Kekkai";\nCFBundleDisplayName = "Kekkai";\n' > "$res/en.lproj/InfoPlist.strings"
printf 'CFBundleName = "结界";\nCFBundleDisplayName = "结界";\n' > "$res/zh-Hans.lproj/InfoPlist.strings"
codesign -f -s - "$sup/libfakeloc.dylib" "$sup/libkekkai.dylib"
# KEKKAI_SIGN 指定本机的签名证书（install.sh 会自动找开发证书）：签名固定，系统授权（如完全磁盘访问权限）重新构建后仍然有效。
# 不设就临时签名，每次构建系统都当成新程序。分发用的安装映像不设，证书名里有开发者的账号
codesign -f -s "${KEKKAI_SIGN:--}" "$app"
echo "$app"
