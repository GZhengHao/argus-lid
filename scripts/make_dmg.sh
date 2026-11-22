#!/bin/zsh
# 打包带「拖到应用程序」布局的 DMG
# 用法：scripts/make_dmg.sh build/Argus.app dist/Argus-1.0.0.dmg
set -e
APP="$1"; OUT="$2"
VOL=Argus
WORK=build/dmg
BG2X=build/obj/dmg_bg.png

rm -rf "$WORK" "$OUT"; mkdir -p "$WORK/stage/.background" "$(dirname "$OUT")"
[[ -f $BG2X ]] || swift scripts/make_dmg_bg.swift $BG2X >/dev/null
sips -z 400 660 $BG2X --out $WORK/bg1x.png >/dev/null
tiffutil -cathidpicheck $WORK/bg1x.png $BG2X -out "$WORK/stage/.background/bg.tiff" 2>/dev/null

ditto "$APP" "$WORK/stage/Argus.app"
ln -s /Applications "$WORK/stage/Applications"

# 若同名卷已挂载，先卸载
[[ -d /Volumes/$VOL ]] && hdiutil detach "/Volumes/$VOL" -quiet -force || true

hdiutil create -quiet -srcfolder "$WORK/stage" -volname $VOL -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1}')
MNT=/Volumes/$VOL

# 用 Finder 设置窗口布局（失败也不影响 DMG 可用，只是没有排版）
osascript <<APPLESCRIPT || echo "warning: Finder layout skipped"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:bg.tiff"
    set position of item "Argus.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$DEV" -quiet
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
echo "DMG: $OUT"
