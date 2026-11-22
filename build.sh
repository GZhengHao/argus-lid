#!/bin/zsh
# 编译 Argus.app（Universal：Apple Silicon + Intel），只需 Xcode Command Line Tools
# 用法：./build.sh          → build/Argus.app
#       ./build.sh release  → 另外打包 dist/Argus-<版本>.zip
set -e
cd "$(dirname "$0")"

VERSION=1.0.0
BUNDLE_ID=io.github.gzhenghao.Argus
APP=build/Argus.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $ARCH-apple-macos26 \
    Sources/*.swift -o build/obj/Argus-$ARCH
done
lipo -create build/obj/Argus-arm64 build/obj/Argus-x86_64 -output "$APP/Contents/MacOS/Argus"

# 图标
if [[ ! -f build/obj/icon.png ]]; then swift scripts/make_icon.swift build/obj/icon.png >/dev/null; fi
ICONSET=build/obj/Argus.iconset
mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s build/obj/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/obj/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/Argus.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Argus</string>
  <key>CFBundleDisplayName</key><string>Argus</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Argus</string>
  <key>CFBundleIconFile</key><string>Argus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "$1" == "release" ]]; then
  mkdir -p dist
  ditto -c -k --keepParent "$APP" "dist/Argus-$VERSION.zip"
  shasum -a 256 "dist/Argus-$VERSION.zip"
fi
