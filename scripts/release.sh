#!/bin/zsh
# Builds a Developer ID signed, notarised and stapled Audiogen.app and zips it for a GitHub release.
#
# Notarisation uses the Apple account signed into Xcode (Xcode › Settings › Accounts), so no
# app-specific password is needed. The archive is also copied into Xcode's Archives folder, so
# Organizer › Distribute App › Direct Distribution works as a manual alternative.
#
# To use notarytool instead, store credentials once and set NOTARY_PROFILE:
#   xcrun notarytool store-credentials audiogen-notary --apple-id <apple-id> --team-id 224XVWZLBK
#   NOTARY_PROFILE=audiogen-notary scripts/release.sh
set -euo pipefail
cd "${0:A:h}/.."
TEAM_ID=224XVWZLBK
export SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: CILLIAN POWER ($TEAM_ID)}"

swift test
scripts/build-app.sh
APP="$PWD/build/Audiogen.app"
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$PLIST")
RELEASE="$PWD/build/release"
ZIP="$PWD/build/Audiogen-$VERSION-arm64.zip"
rm -rf "$RELEASE" "$ZIP"; mkdir -p "$RELEASE"

# Every executable must carry the Developer ID signature, a secure timestamp and the hardened runtime.
check_signed() {
    for binary in "$1/Contents/MacOS/Audiogen" "$1/Contents/Resources/Audiogen_Audiogen.bundle/Contents/Resources/MiniMaxRuntime/mm-server"; do
        details=$(codesign -dvv "$binary" 2>&1)
        [[ "$details" == *"flags=0x10000(runtime)"* && "$details" == *"Timestamp="* && "$details" == *"Authority=Developer ID Application"* ]] || { print -u2 "Not release-signed: $binary"; exit 1; }
    done
    codesign --verify --deep --strict "$1"
}
check_signed "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$RELEASE/upload.zip"
    xcrun notarytool submit "$RELEASE/upload.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    ditto "$APP" "$RELEASE/Audiogen.app"
    xcrun stapler staple "$RELEASE/Audiogen.app"
else
    # A Swift package has no Xcode archive of its own, so wrap the signed app in one.
    ARCHIVE="$RELEASE/Audiogen.xcarchive"
    mkdir -p "$ARCHIVE/Products/Applications"
    ditto "$APP" "$ARCHIVE/Products/Applications/Audiogen.app"
    cat > "$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>ApplicationProperties</key><dict>
<key>ApplicationPath</key><string>Applications/Audiogen.app</string>
<key>Architectures</key><array><string>arm64</string></array>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>SigningIdentity</key><string>$SIGNING_IDENTITY</string>
<key>Team</key><string>$TEAM_ID</string>
</dict>
<key>ArchiveVersion</key><integer>2</integer>
<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
<key>Name</key><string>Audiogen</string>
<key>SchemeName</key><string>Audiogen</string>
</dict></plist>
PLIST
    ORGANIZER="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
    mkdir -p "$ORGANIZER"; ditto "$ARCHIVE" "$ORGANIZER/Audiogen $VERSION ($BUILD).xcarchive"
    cat > "$RELEASE/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>$TEAM_ID</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$RELEASE/export.plist" -exportPath "$RELEASE/upload" -allowProvisioningUpdates
    print "Uploaded for notarisation; waiting for Apple."
    for attempt in {1..90}; do
        if xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$RELEASE" >/dev/null 2>&1; then break; fi
        (( attempt == 90 )) && { print -u2 "Notarisation did not finish within 45 minutes. Check Organizer for its status."; exit 1; }
        sleep 30
    done
fi

FINAL="$RELEASE/Audiogen.app"
check_signed "$FINAL"
xcrun stapler validate "$FINAL"
spctl --assess --type execute -vv "$FINAL"
ditto -c -k --sequesterRsrc --keepParent "$FINAL" "$ZIP"
shasum -a 256 "$ZIP"
print "Ready to upload: $ZIP"
