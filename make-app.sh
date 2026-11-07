#!/bin/bash
# Nobet.app paketini üretir (SwiftPM release + Info.plist + ad-hoc imza).
set -euo pipefail

cd "$(dirname "$0")"
APP="Nobet.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Nobet"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nobet"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Nobet</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.nobet</string>
    <key>CFBundleName</key><string>Nobet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.4</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# NOBET_VERSION ile sürüm geçersiz kılınır (release iş akışı etiketten verir).
if [ -n "${NOBET_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NOBET_VERSION" "$APP/Contents/Info.plist"
fi

# Sabit imza, Tam Disk Erişimi ve Finder izninin kurulumlar arasında kalmasını sağlar.
# SIGN_IDENTITY ile geçersiz kılınır. Sertifika yoksa ad-hoc imza kullanılır.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}"
if [ -n "$IDENTITY" ]; then
  echo "İmza: $IDENTITY"
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "Sertifika bulunamadı. Ad-hoc imza kullanılıyor (izinler her kurulumda sıfırlanabilir)."
  codesign --force --sign - "$APP"
fi
echo "Hazır: $(pwd)/$APP"
