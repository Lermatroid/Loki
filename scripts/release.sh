#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Set VERSION to the release version}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to the release build number}"
: "${APPLE_CERTIFICATE_BASE64:?Missing signing certificate}"
: "${APPLE_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${APPLE_ID:?Missing Apple ID}"
: "${APPLE_TEAM_ID:?Missing Apple team ID}"
: "${APPLE_APP_PASSWORD:?Missing notarization app-specific password}"

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
   [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Expected a numeric x.y.z version and positive build number.' >&2
    exit 1
fi

export ARCH="${ARCH:-arm64}"
TEMP_DIR=$(mktemp -d)
KEYCHAIN="$TEMP_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD=$(openssl rand -hex 32)
cleanup() {
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
umask 077
printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$TEMP_DIR/certificate.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$TEMP_DIR/certificate.p12" -k "$KEYCHAIN" \
    -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

SIGNING_IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" |
    awk -v team="($APPLE_TEAM_ID)" '/"Developer ID Application:/ && index($0, team) { print $2; exit }')
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo 'The certificate must be a valid Developer ID Application identity for APPLE_TEAM_ID.' >&2
    exit 1
fi
export SIGNING_IDENTITY SIGNING_KEYCHAIN="$KEYCHAIN"
bash scripts/build.sh

APP="$PWD/dist/Loki.app"
SUBMISSION="$TEMP_DIR/Loki.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION"
xcrun notarytool store-credentials loki-release --keychain "$KEYCHAIN" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
if ! xcrun notarytool submit "$SUBMISSION" --keychain "$KEYCHAIN" \
    --keychain-profile loki-release --wait --timeout 30m --output-format json > "$TEMP_DIR/notarization.json"; then
    cat "$TEMP_DIR/notarization.json"
    exit 1
fi
STATUS=$(plutil -extract status raw -o - "$TEMP_DIR/notarization.json")
if [[ "$STATUS" != Accepted ]]; then
    SUBMISSION_ID=$(plutil -extract id raw -o - "$TEMP_DIR/notarization.json")
    xcrun notarytool log "$SUBMISSION_ID" --keychain "$KEYCHAIN" --keychain-profile loki-release
    exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ARCHIVE="Loki-$VERSION-macos-$ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
