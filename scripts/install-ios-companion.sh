#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${ROOT}/CompanionIOS/MiWhisperCompanion.xcodeproj"
SCHEME="MiWhisperCompanion"
DERIVED_DATA="${ROOT}/build/CompanionIOSDevice"
XCODE_DEVICE_ID="${MIWHISPER_XCODE_DEVICE_ID:-${MIWHISPER_IOS_DEVICE_ID:-}}"
COREDEVICE_ID="${MIWHISPER_COREDEVICE_ID:-${MIWHISPER_IOS_DEVICE_ID:-${XCODE_DEVICE_ID}}}"
TEAM_ID="${MIWHISPER_IOS_TEAM_ID:-}"

if [[ -z "${XCODE_DEVICE_ID}" ]]; then
  cat >&2 <<'MESSAGE'
Set MIWHISPER_IOS_DEVICE_ID to the paired iPhone device identifier before running this script.

Helpful commands:
  xcrun xctrace list devices
  xcrun devicectl list devices

Example:
  MIWHISPER_IOS_DEVICE_ID=<device-id> MIWHISPER_IOS_TEAM_ID=<team-id> ./scripts/install-ios-companion.sh
MESSAGE
  exit 2
fi

args=(
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -configuration Debug
  -destination "id=${XCODE_DEVICE_ID}"
  -derivedDataPath "${DERIVED_DATA}"
  -allowProvisioningUpdates
)

if [[ -n "${TEAM_ID}" ]]; then
  args+=(DEVELOPMENT_TEAM="${TEAM_ID}")
fi

xcodebuild "${args[@]}" build

APP_PATH="${DERIVED_DATA}/Build/Products/Debug-iphoneos/MiWhisperCompanion.app"
xcrun devicectl device install app --device "${COREDEVICE_ID}" "${APP_PATH}"

if ! launch_output="$(xcrun devicectl device process launch --device "${COREDEVICE_ID}" com.miwhisper.companion 2>&1)"; then
  printf '%s\n' "${launch_output}" >&2
  if grep -qi 'profile has not been explicitly trusted' <<<"${launch_output}"; then
    cat <<'MESSAGE'

MiWhisper Companion was installed, but iOS blocked launch because the developer profile is not trusted yet.
On the iPhone, open Settings > General > VPN & Device Management and trust the Apple Development profile, then open MiWhisper manually.
MESSAGE
    exit 0
  fi
  exit 1
fi

printf '%s\n' "${launch_output}"
