#!/bin/bash
# FORK: build a Release of this fork, sign it with a stable local identity and replace
# /Applications/FluidVoice.app. Override the identity with FLUIDVOICE_SIGNING_IDENTITY.
# The current installation is moved to ~/Applications/FluidVoice-backups first.
#
# Usage: scripts/fork-install.sh [--no-build]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="${FLUIDVOICE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedDataRelease}"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/FluidVoice.app"
INSTALL_PATH="/Applications/FluidVoice.app"
BACKUP_DIR="${HOME}/Applications/FluidVoice-backups"

# Final signature: a stable local identity, like T3 Code ("T3 Local Signing", self-signed, in the
# login keychain). The designated requirement then pins that certificate's hash, so macOS keeps
# Microphone / Accessibility / Screen Recording grants across rebuilds.
SIGNING_IDENTITY_NAME="${FLUIDVOICE_SIGNING_IDENTITY:-T3 Local Signing}"
signing_hash="$(security find-identity -p codesigning \
    | awk -v name="\"${SIGNING_IDENTITY_NAME}\"" 'index($0, name) { print $2; exit }')"
if [ -z "${signing_hash}" ]; then
    echo "Signing identity \"${SIGNING_IDENTITY_NAME}\" not found in the keychain." >&2
    exit 1
fi

# The Xcode build itself signs with the Apple Development identity when one exists (ad hoc
# otherwise); everything is re-signed with the local identity afterwards.
dev_identity_name="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)"
if [ -n "${dev_identity_name}" ]; then
    team_id="${FLUIDVOICE_DEVELOPMENT_TEAM:-$(security find-certificate -c "${dev_identity_name}" -p \
        | openssl x509 -noout -subject -nameopt RFC2253 | sed -n 's/.*OU=\([^,]*\).*/\1/p')}"
    build_signing=(DEVELOPMENT_TEAM="${team_id}")
else
    build_signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

if [ "${1:-}" != "--no-build" ]; then
    echo "Building Release..."
    xcodebuild -project "${PROJECT_DIR}/Fluid.xcodeproj" -scheme Fluid -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "${DERIVED_DATA_PATH}" \
        "${build_signing[@]}" build | grep -E "error:|\*\* BUILD" || true
fi
[ -d "${APP_PATH}" ] || { echo "Build product missing: ${APP_PATH}" >&2; exit 1; }

# Same CTranscribe.framework layout normalisation as build.sh.
framework="${APP_PATH}/Contents/Frameworks/CTranscribe.framework"
if [ -d "${framework}/Versions/A" ]; then
    for link in "Versions/Current:A" "CTranscribe:Versions/Current/CTranscribe" "Resources:Versions/Current/Resources"; do
        path="${framework}/${link%%:*}"
        rm -rf "${path}"
        ln -s "${link#*:}" "${path}"
    done
fi

# Re-sign inside-out. Existing entitlements are kept, minus the ones that need a provisioning
# profile (a self-signed binary carrying them is killed at launch). Requirements are NOT
# preserved, so codesign derives the designated requirement from the local certificate.
sign_component() {
    local target="$1"
    local entitlements
    entitlements="$(mktemp "${TMPDIR:-/tmp}/fluidvoice-entitlements.XXXXXX")"
    codesign --display --entitlements :- "${target}" > "${entitlements}" 2>/dev/null || true
    if [ -s "${entitlements}" ]; then
        for key in com.apple.application-identifier com.apple.developer.team-identifier keychain-access-groups; do
            /usr/libexec/PlistBuddy -c "Delete :${key}" "${entitlements}" >/dev/null 2>&1 || true
        done
        codesign --force --sign "${signing_hash}" --options runtime --timestamp=none \
            --preserve-metadata=identifier,flags --entitlements "${entitlements}" "${target}"
    else
        codesign --force --sign "${signing_hash}" --options runtime --timestamp=none \
            --preserve-metadata=identifier,flags "${target}"
    fi
    rm -f "${entitlements}"
}

echo "Signing with \"${SIGNING_IDENTITY_NAME}\"..."
while IFS= read -r -d '' nested; do
    sign_component "${nested}"
done < <(find "${APP_PATH}/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 2>/dev/null)
while IFS= read -r -d '' nested; do
    sign_component "${nested}"
done < <(find "${APP_PATH}/Contents/Helpers" -type f -perm +111 -print0 2>/dev/null)
sign_component "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"
codesign -d -r- "${APP_PATH}" 2>&1 | grep designated

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
