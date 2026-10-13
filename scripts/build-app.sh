#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/libpq-env.sh
python3 scripts/prepare-telegram.py
python3 scripts/prepare-opus.py
python3 scripts/prepare-opusfile.py
python3 scripts/prepare-mozjpeg.py
python3 scripts/prepare-code-highlight.py
python3 scripts/prepare-rlottie.py
python3 scripts/prepare-vpx.py
python3 scripts/prepare-telegram-voip.py
swift build --product Makosh -j 4
makosh_bin_dir="$(swift build --show-bin-path)"
makosh_bundle="$PWD/.build/Makosh.app"
mkdir -p "$makosh_bundle/Contents/MacOS"
cp "$makosh_bin_dir/Makosh" "$makosh_bundle/Contents/MacOS/Makosh"
mkdir -p "$makosh_bundle/Contents/Frameworks"
cp .local/telegram-voip/build/libMakoshTelegramVoIP.dylib "$makosh_bundle/Contents/Frameworks/"
install_name_tool -delete_rpath "$PWD/.local/telegram-voip/build" "$makosh_bundle/Contents/MacOS/Makosh"
codesign --force --sign - "$makosh_bundle/Contents/Frameworks/libMakoshTelegramVoIP.dylib"
cat > "$makosh_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Makosh</string>
  <key>CFBundleIdentifier</key><string>org.makosh.desktop</string>
  <key>CFBundleName</key><string>Makosh</string>
  <key>CFBundleDisplayName</key><string>Макош</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Макош использует микрофон только после вашего действия для звонка, записи голосового сообщения или круглого видео в выбранном чате Telegram.</string>
  <key>NSCameraUsageDescription</key><string>Макош использует камеру только после вашего действия для видеозвонка или записи круглого видео в выбранном чате Telegram.</string>
  <key>NSHumanReadableCopyright</key><string>2026 Makosh contributors; includes Telegram-iOS. Combined application GPLv3; see third-party notices.</string>
</dict></plist>
PLIST
mkdir -p "$makosh_bundle/Contents/Resources/Licenses"
cp THIRD_PARTY_NOTICES.md LICENSE "$makosh_bundle/Contents/Resources/Licenses/"
cp LICENSES/* "$makosh_bundle/Contents/Resources/Licenses/"
codesign --force --sign - "$makosh_bundle"
codesign --verify --deep --strict "$makosh_bundle"
echo "$makosh_bundle"
