#!/bin/bash
# Sahte veriyle çalışan demo kopyasını kurar ve açar. Gerçek Nobet.app ve ayarları değişmez.
# Kullanım: scripts/demo.sh [uygulama argümanları, örnek: -appearance.theme dark -mainSection Genel]
set -euo pipefail

cd "$(dirname "$0")/.."
./make-app.sh >/dev/null

DEMO="dist/NobetDemo.app"
mkdir -p dist
rm -r "$DEMO" 2>/dev/null || true
cp -R Nobet.app "$DEMO"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.nobet.demo" "$DEMO/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName NobetDemo" "$DEMO/Contents/Info.plist"
codesign --force --sign - "$DEMO"

# Önceki demo ayarları silinir, böylece her çalıştırma aynı sahte veriyle başlar.
defaults delete local.nobet.demo >/dev/null 2>&1 || true
open -n "$DEMO" --env NOBET_DEMO=1 --args "$@"
echo "Demo açıldı: $DEMO"
