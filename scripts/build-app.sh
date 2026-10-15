#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
./scripts/build-minimax-runtime.sh
swift build --scratch-path .build/app-package -c release --arch arm64
BIN_DIR="$(swift build --scratch-path .build/app-package -c release --arch arm64 --show-bin-path)"
APP="$PWD/build/Audiogen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Audiogen" "$APP/Contents/MacOS/Audiogen"
cp -R "$BIN_DIR/Audiogen_Audiogen.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.audiogen.app</string>
<key>CFBundleName</key><string>Audiogen</string>
<key>CFBundleExecutable</key><string>Audiogen</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSArchitecturePriority</key><array><string>arm64</string></array>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconName</key><string>Audiogen</string>
<key>CFBundleIconFile</key><string>Audiogen</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Audio</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.audio</string></array>
</dict></array>
</dict></plist>
PLIST
xcrun actool "$PWD/Icon/Audiogen.icon" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 27.0 --app-icon Audiogen \
  --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
print "$APP"
