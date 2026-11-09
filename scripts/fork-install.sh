#!/bin/bash
# FORK: build a signed Release of this fork and replace /Applications/FluidVoice.app.
# The current installation is moved to ~/Applications/FluidVoice-backups first.
#
# Usage: scripts/fork-install.sh [--no-build]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${FLUIDVOICE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedDataRelease}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/FluidVoice.app"
INSTALL_PATH="/Applications/FluidVoice.app"
BACKUP_DIR="${HOME}/Applications/FluidVoice-backups"

identity_name="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
identity_hash="$(security find-identity -v -p codesigning \
    | sed -n 's/.* \([[:xdigit:]]\{40\}\) "Apple Development:[^"]*".*/\1/p' | head -1)"
if [ -z "${identity_name}" ] || [ -z "${identity_hash}" ]; then
    echo "No Apple Development signing identity found." >&2
    exit 1
fi
team_id="${FLUIDVOICE_DEVELOPMENT_TEAM:-$(security find-certificate -c "${identity_name}" -p \
    | openssl x509 -noout -subject -nameopt RFC2253 | sed -n 's/.*OU=\([^,]*\).*/\1/p')}"

if [ "${1:-}" != "--no-build" ]; then
    echo "Building Release (team ${team_id})..."
    xcodebuild -project "${PROJECT_DIR}/Fluid.xcodeproj" -scheme Fluid -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "${DERIVED_DATA_PATH}" \
        DEVELOPMENT_TEAM="${team_id}" build | grep -E "error:|\*\* BUILD" || true
fi
[ -d "${APP_PATH}" ] || { echo "Build product missing: ${APP_PATH}" >&2; exit 1; }

# Same CTranscribe.framework normalisation as build.sh, then re-sign with the local identity.
framework="${APP_PATH}/Contents/Frameworks/CTranscribe.framework"
if [ -d "${framework}/Versions/A" ]; then
    for link in "Versions/Current:A" "CTranscribe:Versions/Current/CTranscribe" "Resources:Versions/Current/Resources"; do
        path="${framework}/${link%%:*}"
        rm -rf "${path}"
        ln -s "${link#*:}" "${path}"
    done
    codesign --force --sign "${identity_hash}" --options runtime --timestamp=none \
        --preserve-metadata=identifier,requirements,flags "${framework}"
fi
entitlements="$(mktemp "${TMPDIR:-/tmp}/fluidvoice-entitlements.XXXXXX")"
codesign --display --entitlements :- "${APP_PATH}" > "${entitlements}" 2>/dev/null || true
if [ -s "${entitlements}" ]; then
    codesign --force --sign "${identity_hash}" --options runtime --timestamp=none \
        --preserve-metadata=identifier,requirements,flags --entitlements "${entitlements}" "${APP_PATH}"
else
    codesign --force --sign "${identity_hash}" --options runtime --timestamp=none \
        --preserve-metadata=identifier,requirements,flags "${APP_PATH}"
fi
rm -f "${entitlements}"
codesign --verify --deep --strict "${APP_PATH}"

echo "Quitting FluidVoice..."
osascript -e 'tell application id "com.FluidApp.app" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -x FluidVoice >/dev/null || break
    sleep 0.5
done

if [ -d "${INSTALL_PATH}" ]; then
    mkdir -p "${BACKUP_DIR}"
    version="$(defaults read "${INSTALL_PATH}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
    backup="${BACKUP_DIR}/FluidVoice-${version}-$(date +%Y%m%d-%H%M%S).app"
    echo "Backing up current app to ${backup}"
    mv "${INSTALL_PATH}" "${backup}"
fi

echo "Installing ${INSTALL_PATH}"
ditto "${APP_PATH}" "${INSTALL_PATH}"
open "${INSTALL_PATH}"
echo "Done."
