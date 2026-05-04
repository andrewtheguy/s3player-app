#!/usr/bin/env bash
set -euo pipefail

APP_NAME="s3player-app"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  scripts/create-archive-macos.sh [TEAM_ID] [options]
  scripts/create-archive-macos.sh --team-id <TEAM_ID> [options]

Options:
  -t, --team-id TEAM_ID       Developer Team ID.
                              Defaults to the project DEVELOPMENT_TEAM when unique.
  -a, --archive-path PATH     Output path for the macOS .xcarchive.
                              Defaults to ./build/${APP_NAME}-macos.xcarchive.
  -c, --configuration NAME    Build configuration. Defaults to Release.
  --allow-provisioning-updates
                              Let xcodebuild create or update signing assets.
  -h, --help                  Show this help.

Environment overrides:
  TEAM_ID, ARCHIVE_PATH, CONFIGURATION, ALLOW_PROVISIONING_UPDATES
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

TEAM_ID="${TEAM_ID:-}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/build/${APP_NAME}-macos.xcarchive}"
CONFIGURATION="${CONFIGURATION:-Release}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"

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
    -c|--configuration)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      CONFIGURATION="$2"
      shift 2
      ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=1
      shift
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

[[ "$ARCHIVE_PATH" == *.xcarchive ]] || die "--archive-path must end in .xcarchive"

/bin/mkdir -p "$(/usr/bin/dirname "$ARCHIVE_PATH")"

if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "Replacing existing archive: $ARCHIVE_PATH"
  /bin/rm -rf "$ARCHIVE_PATH"
fi

provisioning_args=()
if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  provisioning_args=(-allowProvisioningUpdates)
fi

echo "Creating macOS archive:"
printf '  archive:       %s\n' "$ARCHIVE_PATH"
printf '  configuration: %s\n' "$CONFIGURATION"
printf '  team:          %s\n' "$TEAM_ID"

xcodebuild archive \
  -project "$PROJECT_ROOT/${APP_NAME}.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -sdk macosx \
  -archivePath "$ARCHIVE_PATH" \
  "${provisioning_args[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID"
