#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/libpq-env.sh
if [[ "${1:-}" == "--allow-unconfigured-telegram" ]]; then
    shift
    python3 scripts/prepare-telegram-build-config.py --allow-unconfigured
else
    python3 scripts/prepare-telegram-build-config.py
fi
if [[ $# -ne 0 ]]; then echo "Usage: scripts/build-app.sh [--allow-unconfigured-telegram]" >&2; exit 2; fi
python3 scripts/prepare-telegram.py
python3 scripts/prepare-opus.py
python3 scripts/prepare-opusfile.py
python3 scripts/prepare-mozjpeg.py
python3 scripts/prepare-code-highlight.py
python3 scripts/prepare-rlottie.py
python3 scripts/prepare-vpx.py
python3 scripts/prepare-telegram-voip.py
python3 scripts/prepare-whatsapp.py --sources
swift package resolve
python3 scripts/verify-mail-dependencies.py
python3 scripts/verify-teams-dependencies.py
python3 scripts/verify-telemost-dependencies.py
python3 scripts/prepare-postgres-client.py
swift build --product Makosh -j 4
makosh_bin_dir="$(swift build --show-bin-path)"
makosh_stage="$(mktemp -d "$PWD/.build/Makosh-package.XXXXXX")"
trap 'rm -rf -- "$makosh_stage"' EXIT
makosh_bundle="$makosh_stage/Makosh.app"
mkdir -p "$makosh_bundle/Contents/MacOS"
cp "$makosh_bin_dir/Makosh" "$makosh_bundle/Contents/MacOS/Makosh"
mkdir -p "$makosh_bundle/Contents/Helpers"
cp .local/whatsapp-runtime/MakoshWhatsAppWorker "$makosh_bundle/Contents/Helpers/"
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
  <key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Makosh Telemost OAuth</string><key>CFBundleURLSchemes</key><array><string>org.makosh.desktop.telemost</string></array></dict></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Макош использует микрофон только после вашего действия для звонка и записи голосового сообщения в выбранном чате Telegram или WhatsApp.</string>
  <key>NSCameraUsageDescription</key><string>Макош использует камеру только после вашего действия для видеозвонка в выбранном чате Telegram или WhatsApp, либо записи круглого видео Telegram.</string>
  <key>NSHumanReadableCopyright</key><string>2026 Makosh contributors; includes Telegram-iOS. Combined application GPLv3; see third-party notices.</string>
</dict></plist>
PLIST
mkdir -p "$makosh_bundle/Contents/Resources/Licenses"
cp THIRD_PARTY_NOTICES.md LICENSE "$makosh_bundle/Contents/Resources/Licenses/"
cp -R LICENSES/* "$makosh_bundle/Contents/Resources/Licenses/"
cp -R Dependencies/Mail "$makosh_bundle/Contents/Resources/Licenses/"
cp Dependencies/Teams/README.md "$makosh_bundle/Contents/Resources/Licenses/Teams-README.md"
cp Dependencies/Teams.lock.json "$makosh_bundle/Contents/Resources/Licenses/"
cp Dependencies/Telemost/README.md "$makosh_bundle/Contents/Resources/Licenses/Telemost-README.md"
cp Dependencies/Telemost.lock.json "$makosh_bundle/Contents/Resources/Licenses/"
cp Dependencies/WhatsApp/README.md "$makosh_bundle/Contents/Resources/Licenses/WhatsAppWorker-README.md"
cp .build/MakoshWhatsAppWorker-Source.tar.gz "$makosh_bundle/Contents/Resources/"
python3 scripts/bundle-runtime.py --bundle "$makosh_bundle" \
    --allow-root "$PWD/.local/postgres-client/lib" \
    --allow-root "$(brew --prefix openssl@3)" \
    --replace-libpq "$PWD/.local/postgres-client/lib/libpq.5.dylib"
cp Dependencies/MacRuntime.lock.json "$makosh_bundle/Contents/Resources/"
codesign --force --sign - "$makosh_bundle"
codesign --verify --deep --strict "$makosh_bundle"
python3 scripts/publish-app-bundle.py --stage "$makosh_bundle" --destination "$PWD/.build/Makosh.app"
echo "$PWD/.build/Makosh.app"
