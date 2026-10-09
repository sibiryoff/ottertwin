#!/usr/bin/env bash
# Build OtterTwin (Release, ad-hoc signed) from this checkout and install it.
#
#   scripts/install-local.sh            build and install to /Applications
#   scripts/install-local.sh --dry-run  print the plan, change nothing
#
# An existing OtterTwin.app is kept as "OtterTwin (previous).app" (replacing an
# older "previous"), so the last working build is always one rename away.
# Safe to run repeatedly. Compatible with the bash 3.2 that ships with macOS.
set -euo pipefail

APP_NAME="OtterTwin"
DEST_DIR="/Applications"
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--dest DIR]

Builds ${APP_NAME} (Release, ad-hoc signed) from this checkout and installs it.

  --dry-run   print every step without building, moving or deleting anything
  --dest DIR  install into DIR instead of ${DEST_DIR}
  -h, --help  show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --dest)
            [ $# -ge 2 ] || { echo "error: --dest needs a directory" >&2; exit 2; }
            DEST_DIR="$2"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# Resolve a relative --dest against the caller's directory before cd-ing.
case "$DEST_DIR" in
    /*) ;;
    *) DEST_DIR="$PWD/$DEST_DIR" ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED_DATA="$REPO_ROOT/build/install"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/${APP_NAME}.app"
DEST_DIR="${DEST_DIR%/}"
INSTALLED_APP="$DEST_DIR/${APP_NAME}.app"
PREVIOUS_APP="$DEST_DIR/${APP_NAME} (previous).app"
STAGING_APP="$DEST_DIR/.${APP_NAME}.app.installing-$$"
# An older "previous" is parked here until the new app is in place.
OLD_PREVIOUS_APP="$DEST_DIR/.${APP_NAME} (previous).app.old-$$"

# Print a command; run it unless this is a dry run.
run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if [ "$DRY_RUN" -eq 0 ]; then
        "$@"
    fi
}

step() {
    printf '\n==> %s\n' "$*"
}

cleanup() {
    # Only the per-run staging copy is ever removed here.
    if [ "$DRY_RUN" -eq 0 ] && [ -e "$STAGING_APP" ]; then
        rm -rf "$STAGING_APP"
    fi
}
trap cleanup EXIT

# --- Checks (read-only, also run in --dry-run) --------------------------------

step "Checking tools"
missing=0
if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: Xcode is not available. Install Xcode from the App Store, then run:" >&2
    echo "         sudo xcode-select -s /Applications/Xcode.app" >&2
    missing=1
else
    xcodebuild -version | sed -n 1p
fi
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: XcodeGen is not installed. Install it with:" >&2
    echo "         brew install xcodegen" >&2
    missing=1
else
    echo "XcodeGen $(xcodegen --version 2>/dev/null | sed 's/^Version: //')"
fi
if [ "$missing" -ne 0 ]; then
    exit 1
fi

if GIT_SHA="$(git rev-parse --short=7 HEAD 2>/dev/null)"; then
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        GIT_SHA="${GIT_SHA}-dirty"
    fi
else
    GIT_SHA="unknown"
fi
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"

echo "Commit:      $GIT_SHA"
echo "Install to:  $INSTALLED_APP"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run: nothing will be built, moved or deleted."
fi

# --- Build ---------------------------------------------------------------------

step "Generating OtterTwin.xcodeproj"
run xcodegen generate --spec project.yml

step "Building Release (ad-hoc signed)"
run xcodebuild build \
    -project OtterTwin.xcodeproj \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    "OTTERTWIN_GIT_SHA=$GIT_SHA" \
    "OTTERTWIN_BUILD_DATE=$BUILD_DATE"

step "Verifying the signature of the build"
run codesign --verify --deep --strict "$BUILT_APP"

# --- Install -------------------------------------------------------------------
# The new app is copied next to the destination first, so the installed app is
# only replaced once the complete new copy is in place.

step "Installing"
run mkdir -p "$DEST_DIR"
run ditto "$BUILT_APP" "$STAGING_APP"
run codesign --verify --deep --strict "$STAGING_APP"

MOVED_OLD_PREVIOUS=0
MOVED_CURRENT=0

# Undo the renames done so far, so a failed install never loses the current app.
rollback() {
    echo "error: installation failed; restoring the existing install" >&2
    if [ "$MOVED_CURRENT" -eq 1 ] && [ ! -e "$INSTALLED_APP" ]; then
        mv "$PREVIOUS_APP" "$INSTALLED_APP" ||
            echo "error: could not restore it; your current app is at: $PREVIOUS_APP" >&2
    fi
    if [ "$MOVED_OLD_PREVIOUS" -eq 1 ] && [ ! -e "$PREVIOUS_APP" ]; then
        mv "$OLD_PREVIOUS_APP" "$PREVIOUS_APP" ||
            echo "error: could not restore it; the older previous app is at: $OLD_PREVIOUS_APP" >&2
    fi
    exit 1
}

if [ -e "$INSTALLED_APP" ]; then
    if [ -e "$PREVIOUS_APP" ]; then
        run mv "$PREVIOUS_APP" "$OLD_PREVIOUS_APP" || rollback
        MOVED_OLD_PREVIOUS=1
    fi
    run mv "$INSTALLED_APP" "$PREVIOUS_APP" || rollback
    MOVED_CURRENT=1
else
    echo "(no existing $INSTALLED_APP to keep as previous)"
fi
run mv "$STAGING_APP" "$INSTALLED_APP" || rollback

# Only now, with the new app installed, drop the older previous.
if [ "$MOVED_OLD_PREVIOUS" -eq 1 ]; then
    run rm -rf "$OLD_PREVIOUS_APP" ||
        echo "warning: could not remove $OLD_PREVIOUS_APP; delete it manually" >&2
fi

# --- Report --------------------------------------------------------------------

step "Done"
if [ "$DRY_RUN" -eq 0 ]; then
    PLIST="$INSTALLED_APP/Contents/Info.plist"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo unknown)"
    BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo unknown)"
    STAMPED_SHA="$(/usr/libexec/PlistBuddy -c 'Print :OTGitSHA' "$PLIST" 2>/dev/null || echo unknown)"
    echo "Installed ${APP_NAME} ${VERSION} (${BUILD}), commit ${STAMPED_SHA}, built ${BUILD_DATE}"
    echo "Location:  $INSTALLED_APP"
    if [ -e "$PREVIOUS_APP" ]; then
        echo "Previous:  $PREVIOUS_APP"
    fi
else
    echo "Would install ${APP_NAME} commit ${GIT_SHA} to $INSTALLED_APP"
fi
