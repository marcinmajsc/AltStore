#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METADATA_JSON="$SCRIPT_DIR/metadata.json"
WORKDIR=$(mktemp -d)
APPS_FULL_JSON="$WORKDIR/apps_full.json"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "[]" > "$APPS_FULL_JSON"

jq -c 'to_entries[]' "$METADATA_JSON" | while read -r entry; do
  BUNDLE_ID=$(echo "$entry" | jq -r '.key')
  app_json=$(echo "$entry" | jq '.value')

  DISPLAY_NAME=$(echo "$app_json" | jq -r '.displayName // empty')
  IPA_URL=$(echo "$app_json" | jq -r '.ipaURL // empty')
  DOWNLOAD_URL=$(echo "$app_json" | jq -r '.ipaURL // empty')
  VERSION_DESCRIPTION=$(echo "$app_json" | jq -r '.versionDescription // empty')
  TINT_COLOR=$(echo "$app_json" | jq -r '.tintColor // empty')
  SUBTITLE=$(echo "$app_json" | jq -r '.subtitle // empty')
  DESCRIPTION=$(echo "$app_json" | jq -r '.appDescription // empty')
  ICON_URL=$(echo "$app_json" | jq -r '.iconURL // empty')
  SCREENSHOTS=$(echo "$app_json" | jq -c '.screenshots // []')

  echo "Extracting $DISPLAY_NAME"

  IPA_FILE="$WORKDIR/app.ipa"

  if [[ "$IPA_URL" =~ ^https?:// ]]; then
    echo "Downloading IPA from GitHub Releases..."
    if [[ "$IPA_URL" == *"github.com"* ]]; then
      curl -H "Authorization: token $GITHUB_TOKEN" -L -o "$IPA_FILE" "$IPA_URL"
    else
      curl -L -o "$IPA_FILE" "$IPA_URL"
    fi
  else
    echo "Copying local IPA..."
    cp "$IPA_URL" "$IPA_FILE"
  fi

  TMP_DIR=$(mktemp -d)
  unzip -q "$IPA_FILE" -d "$TMP_DIR"

  APP_PATH=$(find "$TMP_DIR/Payload" -name "*.app" -type d | head -n 1)
  if [[ -z "$APP_PATH" ]]; then
    echo ".app not found"
    rm -rf "$TMP_DIR"
    continue
  fi

  INFO_PLIST="$APP_PATH/Info.plist"
  if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Info.plist not found"
    rm -rf "$TMP_DIR"
    continue
  fi

  EXECUTABLE=$(defaults read "$INFO_PLIST" CFBundleExecutable)
  BUNDLE_ID=$(defaults read "$INFO_PLIST" CFBundleIdentifier)
  VERSION=$(defaults read "$INFO_PLIST" CFBundleShortVersionString)
  MIN_OS_VERSION=$(defaults read "$INFO_PLIST" MinimumOSVersion)

  ENTITLEMENTS_RAW=$(codesign -d --entitlements :- "$APP_PATH/$EXECUTABLE" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')
  ENTITLEMENTS=$(echo "$ENTITLEMENTS_RAW" | jq 'keys')
  PRIVACY=$(plutil -convert json -o - "$INFO_PLIST" | jq 'to_entries | map(select(.key | test("^NS.*UsageDescription$"))) | from_entries')
  SIZE=$(stat -f%z "$IPA_FILE")
  DATE=$(TZ=Europe/Moscow date +"%Y-%m-%dT%H:%M:%S+03:00")

  FULL_APP_JSON=$(jq -n \
    --arg displayName "$DISPLAY_NAME" \
    --arg bundleIdentifier "$BUNDLE_ID" \
    --arg version "$VERSION" \
    --arg minOSVersion "$MIN_OS_VERSION" \
    --arg date "$DATE" \
    --argjson size "$SIZE" \
    --argjson entitlements "$ENTITLEMENTS" \
    --argjson privacy "$PRIVACY" \
    --arg versionDescription "$VERSION_DESCRIPTION" \
    --arg iconURL "$ICON_URL" \
    --arg downloadURL "$DOWNLOAD_URL" \
    --arg tintColor "$TINT_COLOR" \
    --arg subtitle "$SUBTITLE" \
    --arg description "$DESCRIPTION" \
    --argjson screenshots "$SCREENSHOTS" \
    '{
      displayName: $displayName,
      bundleIdentifier: $bundleIdentifier,
      version: $version,
      minOSVersion: $minOSVersion,
      date: $date,
      size: $size,
      entitlements: $entitlements,
      privacy: $privacy,
      versionDescription: $versionDescription,
      iconURL: $iconURL,
      downloadURL: $downloadURL,
      tintColor: $tintColor,
      subtitle: $subtitle,
      description: $description,
      screenshots: $screenshots
    }')

  jq --argjson app "$FULL_APP_JSON" '. + [$app]' "$APPS_FULL_JSON" > "$APPS_FULL_JSON.tmp" && mv "$APPS_FULL_JSON.tmp" "$APPS_FULL_JSON"

done

echo
echo "apps_full.json has been generated"

ALTSTORE_JSON="$SCRIPT_DIR/../repo.json"
SIDESTORE_JSON="$SCRIPT_DIR/../sidestore.json"
ESIGN_JSON="$SCRIPT_DIR/../esign.json"
GBOX_JSON="$SCRIPT_DIR/../gbox.json"
FEATHER_JSON="$SCRIPT_DIR/../feather.json"
SCARLET_JSON="$SCRIPT_DIR/../scarlet.json"

handle_jq_error() {
  local file=$1
  echo "Failed to create $file"
  echo "Last 20 lines:"
  tail -20 "$file"
  echo "Logs:"
  cat "${file}.error"
  exit 1
}

echo "Creating repo.json..."
jq '{
  apps: map({
    name: .displayName,
    bundleIdentifier: .bundleIdentifier,
    developerName: "dvntm",
    subtitle: .subtitle,
    localizedDescription: .description,
    iconURL: .iconURL,
    tintColor: .tintColor,
    screenshots: .screenshots,
    appPermissions: {
      entitlements: .entitlements,
      privacy: .privacy
    },
    versions: [{
      version: .version,
      minOSVersion: .minOSVersion,
      date: .date,
      size: .size,
      downloadURL: .downloadURL,
      localizedDescription: .versionDescription
    }]
  })
}' "$APPS_FULL_JSON" > "$ALTSTORE_JSON" 2> "${ALTSTORE_JSON}.error" || handle_jq_error "$ALTSTORE_JSON"
echo "repo.json has been created"

# sidestore.json
echo "Creating sidestore.json..."
jq '{
  apps: map({
    name: .displayName,
    bundleIdentifier: .bundleIdentifier,
    developerName: "dvntm",
    subtitle: .subtitle,
    version: .version,
    versionDate: .date,
    versionDescription: .versionDescription,
    downloadURL: .downloadURL,
    localizedDescription: .description,
    iconURL: .iconURL,
    tintColor: (.tintColor | sub("^#"; "")),
    screenshotURLs: .screenshots,
    size: .size
  })
}' "$APPS_FULL_JSON" > "$SIDESTORE_JSON" 2> "${SIDESTORE_JSON}.error" || handle_jq_error "$SIDESTORE_JSON"
echo "sidestore.json has been created"

# esign.json
echo "Creating esign.json..."
jq '{
  apps: map({
    name: .displayName,
    bundleIdentifier: .bundleIdentifier,
    developerName: "dvntm",
    version: .version,
    versionDate: .date,
    versionDescription: .versionDescription,
    downloadURL: .downloadURL,
    localizedDescription: .description,
    iconURL: .iconURL,
    tintColor: (.tintColor | sub("^#"; "")),
    isLanZouCloud: 0,
    size: .size,
    type: 1
  })
}' "$APPS_FULL_JSON" > "$ESIGN_JSON" 2> "${ESIGN_JSON}.error" || handle_jq_error "$ESIGN_JSON"
echo "esign.json has been created"

# gbox.json
echo "Creating gbox.json..."
jq '{
  apps: map({
    appType: "SELF_SIGN",
    appCateIndex: 0,
    appUpdateTime: .date,
    appName: .displayName,
    appVersion: .version,
    appImage: .iconURL,
    appPackage: .downloadURL,
    appDescription: .description
  })
}' "$APPS_FULL_JSON" > "$GBOX_JSON" 2> "${GBOX_JSON}.error" || handle_jq_error "$GBOX_JSON"
echo "gbox.json has been created"

# feather.json
echo "Creating feather.json..."
jq '{
  apps: map({
    name: .displayName,
    developerName: "dvntm",
    bundleIdentifier: .bundleIdentifier,
    subtitle: .subtitle,
    version: .version,
    downloadURL: .downloadURL,
    iconURL: .iconURL,
    localizedDescription: .description,
    tintColor: (.tintColor | sub("^#"; "")),
    size: .size,
    screenshotURLs: .screenshots
  })
}' "$APPS_FULL_JSON" > "$FEATHER_JSON" 2> "${FEATHER_JSON}.error" || handle_jq_error "$FEATHER_JSON"
echo "feather.json has been created"

# scarlet.json
echo "Creating scarlet.json..."
jq '{
  apps: map({
    name: .displayName,
    version: .version,
    icon: .iconURL,
    down: .downloadURL,
    category: "Tweaked Apps",
    description: .description,
    bundleID: .bundleIdentifier,
    appstore: .bundleIdentifier,
    changelog: .versionDescription
  })
}' "$APPS_FULL_JSON" > "$SCARLET_JSON" 2> "${SCARLET_JSON}.error" || handle_jq_error "$SCARLET_JSON"
echo "scarlet.json has been created"

rm -f ./*.error
echo "DONE!!!"