#!/bin/bash
# Nobet.app dosyasından DMG üretir. Önce ./make-app.sh çalıştırın.
# Çıktı: dist/Nobet-<sürüm>.dmg ve .sha256 dosyası.
# Uygulama ad-hoc imzalanır. Apple notarization yapılmaz. İlk açılışta sağ tık > Aç gerekir.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="Nobet.app"
[ -d "$APP" ] || { echo "Hata: $APP yok. Önce ./make-app.sh çalıştırın." >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT_DIR="dist"
DMG="$OUT_DIR/Nobet-$VERSION.dmg"
mkdir -p "$OUT_DIR"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Kaynak uygulama değişmez. İmza kopya üzerinde atılır.
ditto "$APP" "$STAGE/$APP"
codesign --force --deep -s - "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Nobet $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "Hazır: $DMG"
