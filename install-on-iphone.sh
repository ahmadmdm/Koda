#!/bin/zsh
# Installs Koda on a connected iPhone: registers the phone in the developer account if needed,
# builds, installs and opens the app.
#   ./install-on-iphone.sh            pick from the connected iPhones
#   ./install-on-iphone.sh <UDID>     a specific iPhone
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=com.koda.ios.t45n44
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

if [[ $# -ge 1 ]]; then
  UDID=$1
else
  xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1
  PHONES=("${(@f)$(/usr/bin/python3 - "$LIST" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS":
        state = d.get("connectionProperties", {}).get("tunnelState", "")
        print(f'{hw.get("udid")}\t{d["deviceProperties"].get("name", "iPhone")}\t{hw.get("marketingName", "")}\t{state}')
EOF
)}")
  PHONES=(${PHONES:#})
  if [[ ${#PHONES} -eq 0 ]]; then
    echo "No iPhone found. Connect it with a cable, unlock it and tap Trust."
    exit 1
  fi
  if [[ ${#PHONES} -eq 1 ]]; then
    CHOICE=1
  else
    echo "Connected iPhones:"
    for i in {1..${#PHONES}}; do
      echo "  $i) ${${PHONES[$i]}//$'\t'/  }"
    done
    read "CHOICE?Number: "
  fi
  UDID=${${PHONES[$CHOICE]}%%$'\t'*}
fi

echo "→ Building for $UDID (registers the phone if it is new)…"
mkdir -p build
if ! xcodebuild -project Koda.xcodeproj -scheme Koda -configuration Release \
  -destination "id=$UDID" -derivedDataPath build/device \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > build/install.log 2>&1; then
  grep -E "error:" build/install.log | sort -u | head -10
  echo "Build failed. Full log: build/install.log"
  exit 1
fi

echo "→ Installing…"
xcrun devicectl device install app --device "$UDID" build/device/Build/Products/Release-iphoneos/Koda.app >/dev/null

echo "→ Opening…"
if ! OUT=$(xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1); then
  echo "Installed, but it couldn't be opened from the Mac:"
  if [[ "$OUT" == *"untrusted"* || "$OUT" == *"profile"* || "$OUT" == *"denied"* ]]; then
    echo "  On the iPhone: Settings › General › VPN & Device Management › trust the developer, then open Koda."
  else
    echo "  The iPhone is locked or no longer connected. Unlock it and open Koda from the Home Screen."
  fi
  exit 0
fi
echo "✓ Koda is installed and open."
