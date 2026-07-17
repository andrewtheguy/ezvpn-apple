#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ezvpn"
PROJECT_NAME="Ezvpn"
SCHEME="Ezvpn"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/create-archive-macos.sh [options]

Builds a macOS .xcarchive, exports a Developer-ID-signed .app, notarizes it with
Apple, staples the ticket, and packages a drag-to-Applications .dmg — the full
pipeline for distributing the app to anyone, outside the Mac App Store.

The tunnel ships as a system extension (target PacketTunnelSysEx), the only
network-extension packaging Apple allows for Developer ID distribution. The app
activates it at first launch via OSSystemExtensionRequest; the user approves it
once in System Settings. System-extension activation only works when the app
runs from /Applications, hence the drag-to-Applications .dmg.

Options:
  -t, --team-id TEAM_ID       Developer Team ID.
                              Defaults to DEVELOPMENT_TEAM from Developer.local.xcconfig.
  -c, --configuration NAME    Build configuration. Defaults to Release for
                              method=developer-id and Debug otherwise: the Release
                              macOS entitlements request the "-systemextension"
                              networkextension value that only Developer ID
                              profiles grant, so a development-signed Release
                              build cannot sign.
  -m, --method METHOD         Export method. Defaults to developer-id.
                              Use "debugging" for a local development-signed .app
                              (skips notarization + .dmg; runs only on machines
                              registered to your team's provisioning profile).
  -a, --archive-path PATH     Output path for the .xcarchive.
                              Defaults to ./build/${APP_NAME}-macos.xcarchive.
  -o, --export-path PATH      Output directory for the exported .app.
                              Defaults to ./build/export-macos.
  -d, --dmg-path PATH         Output .dmg. Defaults to ./build/${APP_NAME}-<version>.dmg.

Notarization credentials (required for method=developer-id unless --skip-notarize).
Use ONE of:
      --notary-profile NAME   A notarytool keychain profile created once with:
                                xcrun notarytool store-credentials NAME \\
                                  --key <AuthKey_XXXX.p8> --key-id <KEY_ID> \\
                                  --issuer <ISSUER_UUID>
  --- or pass the App Store Connect API key directly: ---
      --key PATH              Path to the AuthKey_XXXX.p8 private key.
      --key-id ID             API key ID (the XXXX in the filename).
      --issuer UUID           API key issuer ID (App Store Connect › Users and
                              Access › Integrations › App Store Connect API).
      --skip-notarize         Sign + export only; skip notarization/stapling/.dmg.

Prerequisites you set up once on Apple's side (this script cannot):
  * A "Developer ID Application" certificate in your login keychain
    (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID
    Application). Without it the signing step fails.
  * Developer ID provisioning profiles for the app and the extension in
    ~/Library/Developer/Xcode/UserData/Provisioning Profiles. Xcode generates
    these ("Mac Team Direct Provisioning Profile: <bundle id>") the first time
    you run a Direct Distribution from the Organizer or any
    `xcodebuild -exportArchive -allowProvisioningUpdates` with method
    developer-id, and they stay valid for years.
  * An App Store Connect API key for notarization (the .p8 above).

How developer-id signing works here: xcodebuild cannot produce this build by
itself — automatic signing always archives with a development identity, whose
profile does not grant the "-systemextension" networkextension entitlement the
Release entitlements request, and manual signing rejects the Xcode-managed
Developer ID profiles. So the script archives the app UNSIGNED, then signs
everything itself with codesign: renders the Release entitlements (expanding
the keychain access group and adding the application-/team-identifier pairs
Xcode would add), embeds the Developer ID provisioning profiles, and signs
inside-out with the Hardened Runtime and a secure timestamp — exactly the
bundle layout Xcode's own Direct Distribution produces.

method=debugging still archives + exports through xcodebuild with automatic
development signing (-allowProvisioningUpdates), which needs an Apple Developer
account signed in to Xcode.

Environment overrides:
  TEAM_ID, CONFIGURATION, METHOD, ARCHIVE_PATH, EXPORT_PATH, DMG_PATH,
  NOTARY_PROFILE, NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

TEAM_ID="${TEAM_ID:-}"
CONFIGURATION="${CONFIGURATION:-}"
METHOD="${METHOD:-developer-id}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/build/${APP_NAME}-macos.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$PROJECT_ROOT/build/export-macos}"
DMG_PATH="${DMG_PATH:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY="${NOTARY_KEY:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team-id)        [[ $# -ge 2 ]] || die "$1 requires a value"; TEAM_ID="$2"; shift 2 ;;
    -c|--configuration)  [[ $# -ge 2 ]] || die "$1 requires a value"; CONFIGURATION="$2"; shift 2 ;;
    -m|--method)         [[ $# -ge 2 ]] || die "$1 requires a value"; METHOD="$2"; shift 2 ;;
    -a|--archive-path)   [[ $# -ge 2 ]] || die "$1 requires a value"; ARCHIVE_PATH="$2"; shift 2 ;;
    -o|--export-path)    [[ $# -ge 2 ]] || die "$1 requires a value"; EXPORT_PATH="$2"; shift 2 ;;
    -d|--dmg-path)       [[ $# -ge 2 ]] || die "$1 requires a value"; DMG_PATH="$2"; shift 2 ;;
    --notary-profile)    [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_PROFILE="$2"; shift 2 ;;
    --key)               [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_KEY="$2"; shift 2 ;;
    --key-id)            [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_KEY_ID="$2"; shift 2 ;;
    --issuer)            [[ $# -ge 2 ]] || die "$1 requires a value"; NOTARY_ISSUER="$2"; shift 2 ;;
    --skip-notarize)     SKIP_NOTARIZE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    -*)                  usage >&2; die "unknown option: $1" ;;
    *)                   usage >&2; die "unexpected argument: $1" ;;
  esac
done

# Read a `VAR = value` assignment out of the developer xcconfigs (the local
# override first, then the committed default).
detect_xcconfig_var() {
  local var="$1" xcconfig
  for xcconfig in "$PROJECT_ROOT/Developer.local.xcconfig" "$PROJECT_ROOT/Developer.xcconfig"; do
    [[ -f "$xcconfig" ]] || continue
    /usr/bin/awk -v var="$var" '
      $0 ~ "^[[:space:]]*" var "[[:space:]]*=" {
        sub(/\/\/.*$/, "")
        sub("^[[:space:]]*" var "[[:space:]]*=[[:space:]]*", "")
        gsub(/[[:space:]"]+$/, ""); gsub(/^[[:space:]"]+/, "")
        if ($0 != "") { print $0; found = 1; exit 0 }
      }
      END { if (!found) exit 1 }
    ' "$xcconfig" && return 0
  done
  return 1
}

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(detect_xcconfig_var DEVELOPMENT_TEAM || true)"
fi
[[ -n "$TEAM_ID" ]] || {
  usage >&2
  die "team ID is required: set DEVELOPMENT_TEAM in Developer.local.xcconfig (copy Developer.local.xcconfig.sample) or pass --team-id"
}
if [[ -z "$CONFIGURATION" ]]; then
  # Release entitlements carry the "-systemextension" networkextension value
  # only Developer ID profiles grant, so development-signed methods default to
  # Debug (whose entitlements carry the base value development profiles grant).
  if [[ "$METHOD" == "developer-id" ]]; then CONFIGURATION=Release; else CONFIGURATION=Debug; fi
fi
[[ "$ARCHIVE_PATH" == *.xcarchive ]] || die "--archive-path must end in .xcarchive"
[[ -e "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" ]] || \
  die "${PROJECT_NAME}.xcodeproj not found — run 'xcodegen generate' first"

# Whether this run notarizes: only Developer-ID builds can be notarized.
NOTARIZE=0
if [[ "$METHOD" == "developer-id" && "$SKIP_NOTARIZE" -eq 0 ]]; then
  NOTARIZE=1
fi

# Resolve notarytool credential args up front so we fail fast, before the long
# archive step, if a developer-id build is missing its credentials.
NOTARY_ARGS=()
if [[ "$NOTARIZE" -eq 1 ]]; then
  if [[ -n "$NOTARY_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "$NOTARY_KEY" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER" ]]; then
    [[ -f "$NOTARY_KEY" ]] || die "--key file not found: $NOTARY_KEY"
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    usage >&2
    die "notarization needs credentials: pass --notary-profile NAME, or --key/--key-id/--issuer (or --skip-notarize)"
  fi
fi

# Locate the newest Developer ID (direct-distribution) provisioning profile for
# a full application identifier ("TEAM.bundle.id") among the profiles Xcode has
# downloaded. Direct-distribution profiles are the ones with no
# ProvisionedDevices allowlist (development profiles always carry one).
find_direct_profile() {
  local app_id="$1" dir f plist appid created best="" best_created=""
  for dir in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/*.provisionprofile; do
      [[ -e "$f" ]] || continue
      plist="$(/usr/bin/security cms -D -i "$f" 2>/dev/null)" || continue
      appid="$(printf '%s' "$plist" | /usr/bin/plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - - 2>/dev/null)" || continue
      [[ "$appid" == "$app_id" ]] || continue
      printf '%s' "$plist" | /usr/bin/plutil -extract ProvisionedDevices raw -o - - >/dev/null 2>&1 && continue
      created="$(printf '%s' "$plist" | /usr/bin/plutil -extract CreationDate raw -o - - 2>/dev/null || echo "")"
      if [[ -z "$best" || "$created" > "$best_created" ]]; then
        best="$f"; best_created="$created"
      fi
    done
  done
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

# Render an entitlements file the way Xcode does when signing with a profile:
# expand the keychain access group build setting (must match KEYCHAIN_ACCESS_GROUP
# in project.yml) and add the application-/team-identifier entitlements a macOS
# app must carry alongside an embedded provisioning profile.
render_entitlements() {
  local src="$1" dst="$2" bundle_id="$3"
  /usr/bin/sed "s/\$(KEYCHAIN_ACCESS_GROUP)/${TEAM_ID}.ezvpn.shared/g" "$src" > "$dst"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string ${TEAM_ID}.${bundle_id}" "$dst"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" "$dst"
}

# Resolve every Developer-ID signing asset up front so a missing certificate or
# profile fails fast, before the long archive step.
if [[ "$METHOD" == "developer-id" ]]; then
  BUNDLE_ID_PREFIX="$(detect_xcconfig_var BUNDLE_ID_PREFIX || true)"
  [[ -n "$BUNDLE_ID_PREFIX" ]] || \
    die "BUNDLE_ID_PREFIX not found in Developer.local.xcconfig or Developer.xcconfig"
  APP_BUNDLE_ID="$BUNDLE_ID_PREFIX"
  SYSEX_BUNDLE_ID="$BUNDLE_ID_PREFIX.PacketTunnel"

  SIGN_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | \
    /usr/bin/awk -v team="($TEAM_ID)" '/Developer ID Application/ && index($0, team) { print $2; exit }')"
  [[ -n "$SIGN_IDENTITY" ]] || die "no 'Developer ID Application' certificate for team $TEAM_ID in the keychain — create one in Xcode › Settings › Accounts › Manage Certificates"

  APP_PROFILE="$(find_direct_profile "$TEAM_ID.$APP_BUNDLE_ID" || true)"
  SYSEX_PROFILE="$(find_direct_profile "$TEAM_ID.$SYSEX_BUNDLE_ID" || true)"
  for pair in "$APP_BUNDLE_ID=$APP_PROFILE" "$SYSEX_BUNDLE_ID=$SYSEX_PROFILE"; do
    [[ -n "${pair#*=}" ]] || die "no Developer ID provisioning profile found for ${pair%%=*} — run one Direct Distribution from Xcode's Organizer (or any 'xcodebuild -exportArchive -allowProvisioningUpdates' with method developer-id) so Xcode generates it"
  done
  echo "Signing assets:"
  printf '  identity:      %s\n' "$SIGN_IDENTITY"
  printf '  app profile:   %s\n' "$APP_PROFILE"
  printf '  sysex profile: %s\n' "$SYSEX_PROFILE"
fi

/bin/mkdir -p "$(/usr/bin/dirname "$ARCHIVE_PATH")"

# Clear prior outputs so a mid-flight failure can't leave stale artifacts.
for path in "$ARCHIVE_PATH" "$EXPORT_PATH"; do
  if [[ -e "$path" ]]; then
    echo "Replacing existing: $path"
    /bin/rm -rf "$path"
  fi
done

echo "Creating macOS archive:"
printf '  archive:       %s\n' "$ARCHIVE_PATH"
printf '  configuration: %s\n' "$CONFIGURATION"
printf '  method:        %s\n' "$METHOD"
printf '  team:          %s\n' "$TEAM_ID"

# generic/platform=macOS + -sdk macosx selects the native macos-arm64 slice of
# the two-platform libezvpn.xcframework (see CLAUDE.md).
#
# developer-id archives UNSIGNED: automatic signing would archive with a
# development identity whose profile cannot grant the Release entitlements'
# "-systemextension" networkextension value, and manual signing rejects the
# Xcode-managed Developer ID profiles — so signing happens below with codesign.
if [[ "$METHOD" == "developer-id" ]]; then
  ARCHIVE_SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
else
  ARCHIVE_SIGNING_ARGS=(-allowProvisioningUpdates)
fi

xcodebuild archive \
  -project "$PROJECT_ROOT/${PROJECT_NAME}.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -sdk macosx \
  -archivePath "$ARCHIVE_PATH" \
  "${ARCHIVE_SIGNING_ARGS[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID"

/bin/mkdir -p "$EXPORT_PATH"

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-export.XXXXXX")"
cleanup() { /bin/rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

APP_PATH="$EXPORT_PATH/${APP_NAME}.app"

if [[ "$METHOD" == "developer-id" ]]; then
  ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
  [[ -d "$ARCHIVE_APP" ]] || die "archive did not produce $ARCHIVE_APP"
  /usr/bin/ditto "$ARCHIVE_APP" "$APP_PATH"

  echo "Signing with Developer ID (codesign)…"
  APP_ENTITLEMENTS="$TEMP_DIR/app.entitlements"
  SYSEX_ENTITLEMENTS="$TEMP_DIR/sysex.entitlements"
  render_entitlements "$PROJECT_ROOT/Sources/Ezvpn/Ezvpn.macOS.entitlements" \
    "$APP_ENTITLEMENTS" "$APP_BUNDLE_ID"
  render_entitlements "$PROJECT_ROOT/Sources/PacketTunnel/PacketTunnel.macOS.entitlements" \
    "$SYSEX_ENTITLEMENTS" "$SYSEX_BUNDLE_ID"

  # Hardened Runtime + secure timestamp on every code object: both are
  # notarization requirements.
  SIGN=(/usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY")

  # Sign inside-out: the system extension's nested code, the extension itself,
  # then the app's frameworks, then the app (whose signature seals everything).
  SYSEX_BUNDLE="$(/bin/ls -d "$APP_PATH/Contents/Library/SystemExtensions/"*.systemextension 2>/dev/null | /usr/bin/head -n 1)"
  [[ -n "$SYSEX_BUNDLE" ]] || die "no .systemextension found inside $APP_PATH"
  while IFS= read -r -d '' nested; do
    "${SIGN[@]}" "$nested"
  done < <(/usr/bin/find "$SYSEX_BUNDLE/Contents/Frameworks" -maxdepth 1 \
             \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null)
  /bin/cp "$SYSEX_PROFILE" "$SYSEX_BUNDLE/Contents/embedded.provisionprofile"
  "${SIGN[@]}" --entitlements "$SYSEX_ENTITLEMENTS" "$SYSEX_BUNDLE"

  while IFS= read -r -d '' nested; do
    "${SIGN[@]}" "$nested"
  done < <(/usr/bin/find "$APP_PATH/Contents/Frameworks" -maxdepth 1 \
             \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null)
  /bin/cp "$APP_PROFILE" "$APP_PATH/Contents/embedded.provisionprofile"
  "${SIGN[@]}" --entitlements "$APP_ENTITLEMENTS" "$APP_PATH"

  echo "Verifying signature…"
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_PATH"
else
  EXPORT_OPTIONS_PLIST="$TEMP_DIR/ExportOptions.plist"
  /usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :method string $METHOD" "$EXPORT_OPTIONS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" "$EXPORT_OPTIONS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :destination string export" "$EXPORT_OPTIONS_PLIST"

  echo "Exporting archive:"
  printf '  export: %s\n' "$EXPORT_PATH"
  printf '  method: %s\n' "$METHOD"

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
    -allowProvisioningUpdates

  [[ -d "$APP_PATH" ]] || die "export did not produce $APP_PATH"
fi

if [[ "$NOTARIZE" -eq 0 ]]; then
  echo
  echo "Done: signed .app at $APP_PATH"
  if [[ "$METHOD" != "developer-id" ]]; then
    echo "(method=$METHOD is not a distributable build — no notarization or .dmg.)"
  fi
  exit 0
fi

# Package the .dmg (drag-to-Applications), then notarize + staple the .dmg so
# the whole disk image — and the app inside it — carries a stapled ticket that
# Gatekeeper verifies offline on any Mac.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0")"
[[ -n "$DMG_PATH" ]] || DMG_PATH="$PROJECT_ROOT/build/${APP_NAME}-${VERSION}.dmg"
[[ "$DMG_PATH" == *.dmg ]] || die "--dmg-path must end in .dmg"
[[ -e "$DMG_PATH" ]] && /bin/rm -f "$DMG_PATH"

DMG_STAGE="$TEMP_DIR/dmg"
/bin/mkdir -p "$DMG_STAGE"
/usr/bin/ditto "$APP_PATH" "$DMG_STAGE/${APP_NAME}.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"

echo "Creating disk image:"
printf '  dmg: %s\n' "$DMG_PATH"
/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH"

# Sign the disk image itself (not just the app inside) so Gatekeeper's
# primary-signature assessment of the .dmg passes.
/usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "Notarizing (this uploads to Apple and waits for the result)…"
/usr/bin/xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait

echo "Stapling notarization ticket…"
/usr/bin/xcrun stapler staple "$DMG_PATH"

echo "Verifying Gatekeeper acceptance…"
/usr/sbin/spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || \
  echo "warning: spctl assessment reported an issue; inspect the output above."

echo
echo "Done: notarized, stapled disk image at $DMG_PATH"
echo "Distribute this .dmg. Users drag ezvpn to Applications, launch it, and"
echo "approve the network extension once in System Settings."
