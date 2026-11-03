#!/bin/bash
# 打包安装镜像 build/Kekkai-<版本>.dmg：打开后是一个窗口，把“结界”拖到“应用程序”即可安装。
# 窗口布局（大小、图标位置、背景）存在 Assets/dmg.DS_Store，由访达排好后保存，打包时直接复制，不再驱动访达。
# 它与 Assets/make-dmg-background.swift 的坐标一致；改布局要在访达里重排一次（卷宗名须仍为“结界”），
# 把挂载卷宗里的 .DS_Store 拷回来，并去掉标签栏（ShowTabView）。
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)"
ver="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$src/Info.plist")"
vol="结界"; out="$src/build/Kekkai-$ver.dmg"
unset KEKKAI_SIGN  # 分发包临时签名，不带开发者账号
app="$("$src/scripts/build.sh" | tail -1)"
work="$src/build/dmg-work"; rm -rf "$work"; mkdir -p "$work/stage/.background"
ditto "$app" "$work/stage/Kekkai.app"
ln -s /Applications "$work/stage/Applications"
swift "$src/Assets/make-dmg-background.swift" "$work"
tiffutil -cathidpicheck "$work/dmg-background.png" "$work/dmg-background@2x.png" -out "$work/stage/.background/background.tiff"
cp "$src/Assets/AppIcon.icns" "$work/stage/.VolumeIcon.icns"
cp "$src/Assets/dmg.DS_Store" "$work/stage/.DS_Store"
[ -d "/Volumes/$vol" ] && hdiutil detach "/Volumes/$vol"
hdiutil create -srcfolder "$work/stage" -volname "$vol" -fs HFS+ -format UDRW -ov "$work/rw.dmg"
dev="$(hdiutil attach -readwrite -noverify -noautoopen "$work/rw.dmg" | awk '/Apple_HFS/ {print $1}')"
xcrun SetFile -a C "/Volumes/$vol"  # 用 .VolumeIcon.icns 作卷宗图标
sync
hdiutil detach "$dev"
hdiutil convert "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$out"
rm -rf "$work"
echo "$out"
