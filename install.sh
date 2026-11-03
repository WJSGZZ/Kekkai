#!/bin/bash
# 开发用：编译并装进“应用程序”，同时更新 ~/Library/Application Support/Kekkai/bin 里的命令行
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)"
# 有开发证书就用它签，授权不会因重新构建失效
: "${KEKKAI_SIGN:=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
export KEKKAI_SIGN
built="$("$src/scripts/build.sh" | tail -1)"
# 管理员能直接写系统的“应用程序”；不能写才放个人的 ~/Applications
if [ -w /Applications ]; then app="/Applications/Kekkai.app"; rm -rf "$HOME/Applications/Kekkai.app"; else app="$HOME/Applications/Kekkai.app"; fi
rm -rf "$app"; ditto "$built" "$app"
dst="$HOME/Library/Application Support/Kekkai/bin"; mkdir -p "$dst"
rm -rf "$dst/rules"; ditto "$app/Contents/Resources/support" "$dst"; rm -f "$dst/libkekkaiuser.dylib"
# 聚焦在文件还没放齐时就收录了，记成英文名，中文搜“结界”搜不到；装完让它重新收录
mdimport "$app" || echo "聚焦收录失败，可稍后自行搜索"; echo "Installed / 已安装：$app"
