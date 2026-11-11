#!/bin/sh
# Ekran Kaydı.app'i universal (Apple Silicon + Intel) derler, ad-hoc imzalar ve zip'ler.
# Kullanım: sh scripts/build-app.sh [sürüm] [derleme-no]
# Çıktı: dist/Ekran Kaydı.app ve dist/Ekran-Kaydi-<sürüm>.zip
set -eu

VERSION="${1:-1.1.0}"
BUILD="${2:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Ekran Kaydı"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/Ekran-Kaydi-$VERSION.zip"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/EkranKaydi"

rm -rf "$APP" "$ZIP" "$DIST/Ekran-Kaydi.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EkranKaydi"
# Derleme makinesinin araç zinciri yolu (rpath) pakete girmesin.
otool -l "$APP/Contents/MacOS/EkranKaydi" | awk '/LC_RPATH/{getline; getline; print $2}' | grep '^/Applications/Xcode' | sort -u | while read -r rp; do
  install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/EkranKaydi" 2>/dev/null || true
done
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Geliştirici sertifikası yok: ad-hoc imza (kurulumda "Yine de Aç" gerekir, KURULUM.md).
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# Sürümsüz adlı kopya: güncelleme komutu her zaman releases/latest/download/Ekran-Kaydi.zip'i indirir.
cp "$ZIP" "$DIST/Ekran-Kaydi.zip"
echo "app: $APP"
echo "zip: $ZIP"
lipo -archs "$APP/Contents/MacOS/EkranKaydi"
