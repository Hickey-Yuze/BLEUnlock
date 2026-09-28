#!/bin/bash
# BLEUnlock 手动构建脚本（无需完整 Xcode，使用 Command Line Tools 的 swiftc/clang）
#
# 用法:  ./build.sh
# 产物:  build/BLEUnlock.app
#
# 与原 Xcode 工程的差异（原因见各处注释）:
#   - 程序入口由 main.swift 提供（无 MainMenu.nib）
#   - AboutBox 为纯代码窗口（无 ibtool 编译 xib）
#   - 菜单栏图标从 bundle 资源加载 PDF（无 actool 编译 Assets.car）
#   - 私有框架以 -framework 显式链接（login / MediaRemote）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BLEUnlock"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"

echo "==> 清理"
rm -rf "$APP" "$BUILD_DIR/lowlevel.o" "$BUILD_DIR/AppIcon.iconset" "$BUILD_DIR/AppIcon.icns"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/AppIcon.iconset"

echo "==> 生成 AppIcon.icns（源: Resources/app-logo.png）"
LOGO="BLEUnlock/Resources/app-logo.png"
ICONSET="$BUILD_DIR/AppIcon.iconset"
sips -z 16 16    "$LOGO" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32    "$LOGO" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32    "$LOGO" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64    "$LOGO" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128  "$LOGO" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256  "$LOGO" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256  "$LOGO" --out "$ICONSET/icon_256x256.png"    >/dev/null
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "==> 编译 lowlevel.c"
clang -O2 -arch arm64 -isysroot "$SDK" \
    -c BLEUnlock/lowlevel.c -o "$BUILD_DIR/lowlevel.o"

echo "==> 生成 login.framework 链接桩（SACLockScreenImmediate）"
# 新版 macOS 已从系统目录移除 login.framework 的链接桩，但运行时符号仍在
# dyld shared cache 中。此处用 tapi tbd 声明链接期承诺，运行时由 install-name 解析。
cat > "$BUILD_DIR/login.tbd" <<'TBD'
--- !tapi-tbd-v3
archs:           [ arm64, x86_64 ]
platform:        macosx
install-name:    /System/Library/PrivateFrameworks/login.framework/Versions/A/login
current-version: 0
compatibility-version: 0
exports:
  - archs:           [ arm64, x86_64 ]
    symbols:         [ _SACLockScreenImmediate ]
TBD

echo "==> 编译 Swift + 链接"
# CLT 26 的 SwiftBridging module 在 usr/include/module.modulemap 与
# usr/include/swift/module.modulemap 两处重复定义，同时加载即冲突。
# 用 VFS overlay 的 remappings 把后者重定向到空文件，消除重复定义。
printf '// (blocked by VFS overlay to avoid duplicate SwiftBridging module)\n' > "$BUILD_DIR/empty.modulemap"
cat > "$BUILD_DIR/overlay.yaml" <<EOF
{
  'version': 0,
  'roots': [
    {
      'name': '/Library/Developer/CommandLineTools/usr/include/swift',
      'type': 'directory',
      'contents': [
        {
          'name': 'module.modulemap',
          'type': 'file',
          'external-contents': '$PWD/$BUILD_DIR/empty.modulemap'
        }
      ]
    }
  ]
}
EOF
swiftc \
    -swift-version 5 \
    -O \
    -sdk "$SDK" \
    -Xcc -ivfsoverlay -Xcc "$PWD/$BUILD_DIR/overlay.yaml" \
    -Xfrontend -interface-compiler-version -Xfrontend 6.2 \
    -import-objc-header BLEUnlock/BLEUnlock-Bridging-Header.h \
    BLEUnlock/main.swift \
    BLEUnlock/AppDelegate.swift \
    BLEUnlock/TransitionController.swift \
    BLEUnlock/BLE.swift \
    BLEUnlock/LEDeviceInfo.swift \
    BLEUnlock/appleDeviceNames.swift \
    BLEUnlock/checkUpdate.swift \
    BLEUnlock/AboutBox.swift \
    "$BUILD_DIR/lowlevel.o" \
    -Xlinker -F -Xlinker /System/Library/PrivateFrameworks \
    -Xlinker "$BUILD_DIR/login.tbd" \
    -framework MediaRemote \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> 组装 bundle"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>BLEUnlock</string>
	<key>CFBundleExecutable</key>
	<string>BLEUnlock</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>jp.sone.BLEUnlock</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>BLEUnlock</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.12.2</string>
	<key>CFBundleVersion</key>
	<string>797</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>de</string>
		<string>ja</string>
		<string>zh-Hans</string>
		<string>da</string>
		<string>nb</string>
		<string>sv</string>
		<string>tr</string>
	</array>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>BLEUnlock uses Bluetooth to detect devices.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSUserNotificationAlertStyle</key>
	<string>banner</string>
</dict>
</plist>
PLIST

R="$APP/Contents/Resources"
cp BLEUnlock/Resources/lock.html BLEUnlock/Resources/unlock.html "$R/"
cp BLEUnlock/Resources/lock.wav BLEUnlock/Resources/unlock.wav "$R/"
cp BLEUnlock/Resources/StatusBarConnected.pdf BLEUnlock/Resources/StatusBarDisconnected.pdf "$R/"
cp "$BUILD_DIR/AppIcon.icns" "$R/AppIcon.icns"
for l in Base de zh-Hans ja da nb sv tr; do
    if [ -f "BLEUnlock/$l.lproj/Localizable.strings" ]; then
        mkdir -p "$R/$l.lproj"
        cp "BLEUnlock/$l.lproj/Localizable.strings" "$R/$l.lproj/"
    fi
done

echo "==> 签名（ad-hoc）"
codesign --force --sign - --entitlements BLEUnlock/BLEUnlock.entitlements "$APP"

echo "==> 完成: $APP"
