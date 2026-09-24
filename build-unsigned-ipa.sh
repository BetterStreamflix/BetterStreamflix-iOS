#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_FILE="$SCRIPT_DIR/BetterStreamflix.xcodeproj/project.pbxproj"
PROJECT_YAML="$SCRIPT_DIR/project.yml"
XCODE_PROJECT="$SCRIPT_DIR/BetterStreamflix.xcodeproj"
SCHEME="BetterStreamflix"
APP_NAME="BetterStreamflix"

if [[ $# -gt 2 ]]; then
    echo "Usage: $0 [version] [build]" >&2
    exit 2
fi

# Prefer explicit arg, then BUILD_VERSION (CI), then interactive prompt.
VERSION="${1:-${BUILD_VERSION:-}}"
BUILD_NUMBER="${2:-${BUILD_NUMBER:-}}"
if [[ -z "$VERSION" ]]; then
    if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "Usage in CI: $0 <version> [build]  or  BUILD_VERSION=<version> BUILD_NUMBER=<n> $0" >&2
        exit 2
    fi
    read -r -p "What version should I build? (example: 0.0.1): " VERSION
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(sed -nE 's/.*CURRENT_PROJECT_VERSION: ([0-9]+).*/\1/p' "$PROJECT_YAML" | head -1)"
    BUILD_NUMBER="${BUILD_NUMBER:-1}"
fi

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo "Invalid version '$VERSION'. Use one to three numeric parts, such as 2, 2.1, or 2.1.3." >&2
    exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Invalid build number '$BUILD_NUMBER'." >&2
    exit 2
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Xcode is required, but xcodebuild was not found." >&2
    exit 1
fi

PBX_MATCHES="$(grep -Ec 'MARKETING_VERSION = [0-9]+([.][0-9]+){0,2};' "$PROJECT_FILE" || true)"
YAML_MATCHES="$(grep -Ec 'MARKETING_VERSION: [0-9]+([.][0-9]+){0,2}$' "$PROJECT_YAML" || true)"

if [[ "$PBX_MATCHES" -lt 1 || "$YAML_MATCHES" -ne 1 ]]; then
    echo "Could not safely locate all project version settings; no files were changed." >&2
    exit 1
fi

# Update both the checked-in Xcode project and the XcodeGen source of truth.
sed -E -i '' "s/(MARKETING_VERSION = )[0-9]+([.][0-9]+){0,2};/\\1${VERSION};/g" "$PROJECT_FILE"
sed -E -i '' "s/(MARKETING_VERSION: )[0-9]+([.][0-9]+){0,2}$/\\1${VERSION}/" "$PROJECT_YAML"
sed -E -i '' "s/(CURRENT_PROJECT_VERSION = )[0-9]+;/\\1${BUILD_NUMBER};/g" "$PROJECT_FILE"
sed -E -i '' "s/(CURRENT_PROJECT_VERSION: )[0-9]+$/\\1${BUILD_NUMBER}/" "$PROJECT_YAML"

if [[ "$(grep -Fc "MARKETING_VERSION = ${VERSION};" "$PROJECT_FILE")" -ne "$PBX_MATCHES" ]] || \
   ! grep -Fq "MARKETING_VERSION: ${VERSION}" "$PROJECT_YAML"; then
    echo "The version update could not be verified. Stopping before the build." >&2
    exit 1
fi

if ! grep -Fq "CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};" "$PROJECT_FILE"; then
    echo "The build number update could not be verified. Stopping before the build." >&2
    exit 1
fi

OUTPUT_DIR="$SCRIPT_DIR/build/unsigned-ipa/$VERSION"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
PACKAGE_DIR="$OUTPUT_DIR/package"
IPA_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-unsigned.ipa"

rm -rf "$OUTPUT_DIR"
mkdir -p "$PACKAGE_DIR/Payload"

echo "Version changed to $VERSION ($BUILD_NUMBER) in the Xcode project."
echo "Building an unsigned Release app..."

xcodebuild \
    -project "$XCODE_PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Build completed, but the BetterStreamflix app bundle was not found at: $APP_PATH" >&2
    exit 1
fi

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
    echo "Built app reports version $BUILT_VERSION instead of $VERSION; IPA was not created." >&2
    exit 1
fi

cp -R "$APP_PATH" "$PACKAGE_DIR/Payload/"
(
    cd "$PACKAGE_DIR"
    /usr/bin/zip -qry "$IPA_PATH" Payload
)

if /usr/bin/codesign -dv "$PACKAGE_DIR/Payload/${APP_NAME}.app" >/dev/null 2>&1; then
    echo "The packaged BetterStreamflix app unexpectedly has a code signature; refusing to label it unsigned." >&2
    rm -f "$IPA_PATH"
    exit 1
fi

rm -rf "$PACKAGE_DIR"

echo
echo "Unsigned BetterStreamflix IPA created successfully:"
echo "$IPA_PATH"
