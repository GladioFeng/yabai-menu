#!/bin/sh
# 代码目的：构建可直接启动的原生菜单栏程序。
#
# 代码逻辑：
# 1. 使用本机 Xcode 编译 Intel 与 Apple Silicon 两个架构。
# 2. 在临时目录生成 .app、签名和 ZIP，校验通过后替换成品。
# 3. 发布失败时恢复旧产物，输出启动路径和 SHA-256。
#
# 必需输入：
# - Xcode，以及当前目录中的 Swift 源码。
#
# 预期输出：
# - dist/Yabai Menu.app、版本化 ZIP、SHA-256 和 .build/build.log。
set -eu
cd "$(dirname "$0")"
version=1.0.0
build=25
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR=$(/usr/bin/xcode-select -p)
    export DEVELOPER_DIR
fi
if [ ! -d "$DEVELOPER_DIR/Platforms/MacOSX.platform" ]; then
    printf 'Set DEVELOPER_DIR to a full Xcode installation, then run this script again.\n' >&2
    exit 1
fi
mkdir -p .build dist
if ! /usr/bin/xcrun swift build -c release --arch x86_64 --arch arm64 > .build/build.log 2>&1; then
    printf 'Build failed. See %s/.build/build.log\n' "$PWD" >&2
    exit 1
fi
binary_dir=$(/usr/bin/xcrun swift build -c release --arch x86_64 --arch arm64 --show-bin-path)
archive="Yabai-Menu-$version-universal.zip"
checksum="$archive.sha256"
stage=$(mktemp -d dist/.package.XXXXXX)
publishing=false
cleanup() {
    result=$?
    trap - 0
    if [ "$publishing" = true ]; then
        for file in 'Yabai Menu.app' "$archive" "$checksum"; do
            if [ -e "$stage/previous/$file" ] || [ -L "$stage/previous/$file" ]; then
                rm -rf "dist/$file"
                if ! mv "$stage/previous/$file" "dist/$file"; then
                    printf 'Restore failed; previous outputs remain in %s/previous\n' "$stage" >&2
                    exit 1
                fi
            elif [ ! -e "$stage/new/$file" ]; then
                rm -rf "dist/$file"
            fi
        done
    fi
    rm -rf "$stage"
    exit "$result"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
mkdir -p "$stage/new" "$stage/previous"
app="$stage/new/Yabai Menu.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/YabaiMenu" "$app/Contents/MacOS/YabaiMenu"
cp LICENSE "$app/Contents/Resources/LICENSE"
/usr/bin/xcrun swift scripts/make-icon.swift .build/AppIcon.iconset
/usr/bin/iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>YabaiMenu</string>
<key>CFBundleIdentifier</key><string>dev.gladio.yabai-menu</string>
<key>CFBundleName</key><string>Yabai Menu</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>GPL-3.0-only. Includes window-event logic derived from a-bar.</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --options runtime "$app"
codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/lipo "$app/Contents/MacOS/YabaiMenu" -verify_arch x86_64 arm64
/usr/bin/ditto -c -k --keepParent "$app" "$stage/new/$archive"
/usr/bin/unzip -tq "$stage/new/$archive"
(cd "$stage/new" && /usr/bin/shasum -a 256 "$archive" > "$checksum")
publishing=true
for file in 'Yabai Menu.app' "$archive" "$checksum"; do
    if [ -e "dist/$file" ] || [ -L "dist/$file" ]; then mv "dist/$file" "$stage/previous/$file"; fi
    mv "$stage/new/$file" "dist/$file"
done
publishing=false
printf 'Built: %s/dist/Yabai Menu.app\n' "$PWD"
cat "dist/$checksum"
