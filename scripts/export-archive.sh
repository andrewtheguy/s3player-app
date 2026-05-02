#!/usr/bin/env bash
set -euo pipefail

APP_NAME="s3player-app"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/export-archive.sh [TEAM_ID] [options]
  scripts/export-archive.sh --team-id <TEAM_ID> [options]

Options:
  -t, --team-id TEAM_ID    Developer Team ID.
                           Defaults to the project DEVELOPMENT_TEAM when unique.
  -a, --archive-path PATH  Path to the .xcarchive.
                           Defaults to ./build/${APP_NAME}.xcarchive.
  -o, --export-path PATH   Output directory for the exported .ipa.
                           Defaults to ./build/export.
  -m, --method METHOD      Export method. Defaults to debugging.
  -h, --help               Show this help.

Environment overrides:
  TEAM_ID, ARCHIVE_PATH, EXPORT_PATH, METHOD
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

TEAM_ID="${TEAM_ID:-}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/build/${APP_NAME}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$PROJECT_ROOT/build/export}"
METHOD="${METHOD:-debugging}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--team-id)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      TEAM_ID="$2"
      shift 2
      ;;
    -a|--archive-path)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    -o|--export-path)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      EXPORT_PATH="$2"
      shift 2
      ;;
    -m|--method)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      METHOD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      die "unknown option: $1"
      ;;
    *)
      if [[ -n "$TEAM_ID" ]]; then
        usage >&2
        die "unexpected argument: $1"
      fi
      TEAM_ID="$1"
      shift
      ;;
  esac
done

detect_project_team_id() {
  local project_file="$PROJECT_ROOT/${APP_NAME}.xcodeproj/project.pbxproj"
  [[ -f "$project_file" ]] || return 1

  /usr/bin/awk '
    /DEVELOPMENT_TEAM = / {
      value = $0
      sub(/.*DEVELOPMENT_TEAM = /, "", value)
      sub(/;.*/, "", value)
      gsub(/[ \t"]/, "", value)
      if (value != "" && !seen[value]++) {
        ids[++count] = value
      }
    }
    END {
      if (count == 1) {
        print ids[1]
      } else if (count > 1) {
        exit 2
      } else {
        exit 1
      }
    }
  ' "$project_file"
}

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(detect_project_team_id || true)"
fi

[[ -n "$TEAM_ID" ]] || {
  usage >&2
  die "team ID is required because no unique DEVELOPMENT_TEAM was found in the project"
}

validate_ios_archive() {
  local archive_path="$1"
  local archive_info="$archive_path/Info.plist"
  local app_path
  local app_info
  local platform_name
  local supported_platform
  local requires_iphone_os
  local device_family

  [[ -f "$archive_info" ]] || die "archive Info.plist is missing: $archive_info"

  app_path="$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:ApplicationPath" "$archive_info" 2>/dev/null || true)"
  [[ -n "$app_path" ]] || die "archive does not contain an application path"

  app_info="$archive_path/Products/$app_path/Info.plist"
  [[ -f "$app_info" ]] || die "archived app Info.plist is missing: $app_info"

  platform_name="$(/usr/libexec/PlistBuddy -c "Print :DTPlatformName" "$app_info" 2>/dev/null || true)"
  supported_platform="$(/usr/libexec/PlistBuddy -c "Print :CFBundleSupportedPlatforms:0" "$app_info" 2>/dev/null || true)"
  requires_iphone_os="$(/usr/libexec/PlistBuddy -c "Print :LSRequiresIPhoneOS" "$app_info" 2>/dev/null || true)"
  device_family="$(/usr/libexec/PlistBuddy -c "Print :UIDeviceFamily:0" "$app_info" 2>/dev/null || true)"

  [[ "$platform_name" == "iphoneos" ]] || die "archive is not an iOS device archive; DTPlatformName is '$platform_name'"
  [[ "$supported_platform" == "iPhoneOS" ]] || die "archive is not an iOS archive; CFBundleSupportedPlatforms[0] is '$supported_platform'"
  [[ "$requires_iphone_os" == "true" ]] || die "archive is not an iOS app archive; LSRequiresIPhoneOS is '$requires_iphone_os'"
  [[ -n "$device_family" ]] || die "archive is not an iOS app archive; UIDeviceFamily is missing"
}

[[ -d "$ARCHIVE_PATH" ]] || die "archive does not exist: $ARCHIVE_PATH; run scripts/archive-ios.sh first"
validate_ios_archive "$ARCHIVE_PATH"

/bin/mkdir -p "$EXPORT_PATH"

TEMP_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}-export.XXXXXX")"
cleanup() {
  /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

EXPORT_OPTIONS_PLIST="$TEMP_DIR/ExportOptions.plist"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :method string $METHOD" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :signingStyle string automatic" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :destination string export" "$EXPORT_OPTIONS_PLIST"

echo "Exporting archive:"
printf '  archive: %s\n' "$ARCHIVE_PATH"
printf '  export:  %s\n' "$EXPORT_PATH"
printf '  method:  %s\n' "$METHOD"
printf '  team:    %s\n' "$TEAM_ID"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
