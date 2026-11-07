#!/bin/bash
# Nobet'ı derler ve /Applications altına kurar.
# Mevcut kurulum varsa önce çalışan uygulamayı kapatır, sonra değiştirir.
set -euo pipefail

cd "$(dirname "$0")"
TARGET="/Applications/Nobet.app"

./make-app.sh

if pgrep -x Nobet > /dev/null; then
    osascript -e 'tell application "Nobet" to quit' > /dev/null 2>&1 || pkill -x Nobet || true
    sleep 2
fi

if [ -d "$TARGET" ]; then
    echo "Mevcut kurulum değiştiriliyor: $TARGET"
    rm -rf "$TARGET"
fi

cp -R Nobet.app "$TARGET"
codesign --verify --deep "$TARGET"
echo "Kuruldu: $TARGET"
open "$TARGET"
