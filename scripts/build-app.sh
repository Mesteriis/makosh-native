#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/libpq-env.sh
swift build --product Makosh
makosh_bin_dir="$(swift build --show-bin-path)"
makosh_bundle="$PWD/.build/Makosh.app"
mkdir -p "$makosh_bundle/Contents/MacOS"
cp "$makosh_bin_dir/Makosh" "$makosh_bundle/Contents/MacOS/Makosh"
cat > "$makosh_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Makosh</string>
  <key>CFBundleIdentifier</key><string>org.makosh.desktop</string>
  <key>CFBundleName</key><string>Makosh</string>
  <key>CFBundleDisplayName</key><string>Макош</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>2026 Makosh contributors · MIT</string>
</dict></plist>
PLIST
codesign --force --sign - "$makosh_bundle"
codesign --verify --strict "$makosh_bundle"
echo "$makosh_bundle"
