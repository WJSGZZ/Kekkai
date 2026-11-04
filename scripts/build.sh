#!/bin/bash
# 编译出自包含的 build/Kekkai.app：界面、命令行、注入库和规则都在包里，
# 第一次打开（或版本变化）时由 App 自己装到 ~/Library/Application Support/Kekkai/bin
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
app="$src/build/Kekkai.app"; res="$app/Contents/Resources"; sup="$res/support"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$sup"
# 和 Info.plist 的 LSMinimumSystemVersion 一致；不写的话 swiftc 按本机系统版本编译，旧系统打不开
min=14.0
export MACOSX_DEPLOYMENT_TARGET=$min
# Swift 程序编成通用二进制（Apple 芯片和 Intel）：两种架构各编一次再合并
universal() {
  local out=$1; shift
  for a in arm64 x86_64; do swiftc -O -target "$a-apple-macos$min" -o "$out.$a" "$@"; done
  lipo -create -output "$out" "$out.arm64" "$out.x86_64"; rm "$out.arm64" "$out.x86_64"
}
universal "$app/Contents/MacOS/Kekkai" -parse-as-library "$src/Sources/Kekkai.swift"
clang -dynamiclib -fobjc-arc -Wno-deprecated-declarations -arch arm64 -arch x86_64 -framework Foundation -framework CoreLocation \
  "$src/Sources/fakeloc.m" -o "$sup/libfakeloc.dylib"
clang -dynamiclib -Wno-deprecated-declarations -arch arm64 -arch x86_64 -framework CoreFoundation -framework IOKit -framework SystemConfiguration -framework DiskArbitration -framework CoreGraphics -framework ColorSync -framework Network -framework Security -framework CoreServices -lobjc \
  "$src/Sources/inject.c" -o "$sup/libkekkai.dylib"
clang -fobjc-arc -arch arm64 -arch x86_64 -framework AppKit -framework CoreGraphics "$src/Sources/relay.m" -o "$sup/kekkai-relay"
universal "$sup/kekkai" "$src/Sources/cli.swift"  # 命令行，编译成单个程序，不依赖系统 Python
cp -R "$src/rules" "$sup/rules"
sips -Z 512 "$src/Assets/icon-1024.png" --out "$sup/badge.png" >/dev/null  # 程序坞图标的结界角标
# 内容变了才重装支持文件：用支持文件本身的哈希作版本
(cd "$sup" && find . -type f ! -name build-id -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16) > "$sup/build-id"
cp "$src/Info.plist" "$app/Contents/Info.plist"
cp "$src/Assets/AppIcon.icns" "$res/AppIcon.icns"
for l in en zh-Hans; do mkdir -p "$res/$l.lproj"; done
printf 'CFBundleName = "Kekkai";\nCFBundleDisplayName = "Kekkai";\n' > "$res/en.lproj/InfoPlist.strings"
printf 'CFBundleName = "结界";\nCFBundleDisplayName = "结界";\n' > "$res/zh-Hans.lproj/InfoPlist.strings"
codesign -f -s - "$sup/libfakeloc.dylib" "$sup/libkekkai.dylib" "$sup/kekkai-relay" "$sup/kekkai"
# KEKKAI_SIGN 指定本机的签名证书（install.sh 会自动找开发证书）：签名固定，系统授权（如完全磁盘访问权限）重新构建后仍然有效。
# 不设就临时签名，每次构建系统都当成新程序。分发用的安装映像不设，证书名里有开发者的账号
codesign -f -s "${KEKKAI_SIGN:--}" "$app"
echo "$app"
