#!/bin/sh
# thermac installer: builds the menu bar app from source and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/umairleo1/thermac/main/install.sh | sh
#
# Options (after `sh -s --`):
#   --uninstall      remove the app, the recorder and the `thermac` command (keeps data)
#   --purge          with --uninstall: also delete recorded data
#   --ref NAME       build a branch or tag instead of main
#
# Requires macOS 14+, Apple Silicon and the Xcode Command Line Tools (Swift 6).
# Nothing is installed outside your home folder and no sudo is needed.

set -eu

REPO="umairleo1/thermac"
REF="main"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/ThermacBar.app"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/Library/Application Support/thermac"
UNINSTALL=0
PURGE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        --ref) shift; REF="${1:?--ref needs a value}" ;;
        -h|--help)
            echo "Usage: install.sh [--uninstall [--purge]] [--ref NAME]"
            echo "  (no options)  build and install thermac from github.com/$REPO"
            echo "  --uninstall   remove the app, the recorder and the thermac command (keeps data)"
            echo "  --purge       with --uninstall: also delete recorded data"
            echo "  --ref NAME    build a branch or tag instead of main"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m'); RESET=$(printf '\033[0m')
else
    BOLD=""; DIM=""; RED=""; GREEN=""; RESET=""
fi
step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
die()  { printf '%sError:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

stop_everything() {
    pkill -x ThermacBar 2>/dev/null || true
    uid=$(id -u)
    launchctl bootout "gui/$uid/com.thermac.bar.recorder" 2>/dev/null || true
    if [ -f "$HOME/Library/LaunchAgents/com.thermac.recorder.plist" ]; then
        launchctl bootout "gui/$uid/com.thermac.recorder" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/com.thermac.recorder.plist"
    fi
}

# --- Uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
    step "Uninstalling thermac"
    stop_everything
    rm -rf "$APP"
    [ -L "$BIN_DIR/thermac" ] && rm -f "$BIN_DIR/thermac"
    ok "Removed the app, the background recorder and the thermac command"
    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$DATA_DIR" "$HOME/Library/Logs/thermac"
        ok "Deleted recorded data"
    else
        printf '%sRecorded data kept in %s (use --purge to delete it)%s\n' "$DIM" "$DATA_DIR" "$RESET"
    fi
    exit 0
fi

# --- Checks ------------------------------------------------------------------
step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || die "thermac only runs on macOS."
[ "$(uname -m)" = "arm64" ] || die "thermac needs a Mac with Apple Silicon (M1 or later)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "thermac needs macOS 14 Sonoma or later (this Mac has $(sw_vers -productVersion))."
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    die "The Xcode Command Line Tools are needed to build thermac.
       Install them with:  xcode-select --install
       then run this installer again."
fi
swift_major=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\).*/\1/p' | head -1)
[ "${swift_major:-0}" -ge 6 ] || die "thermac needs Swift 6 or later (found ${swift_major:-none}).
       Update the Command Line Tools: softwareupdate --list, or reinstall with xcode-select --install."
ok "macOS $(sw_vers -productVersion), $(sysctl -n hw.model), Swift $swift_major"

# --- Download ----------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/thermac-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
step "Downloading thermac ($REF)"
curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar -xz -C "$WORK" --strip-components=1 \
    || die "Couldn't download https://github.com/$REPO (ref: $REF)."
ok "Source downloaded"

# --- Build -------------------------------------------------------------------
step "Building (this takes a minute or two the first time)"
(
    cd "$WORK"
    swift build -c release --product ThermacBar >"$WORK/build.log" 2>&1 \
        && swift build -c release --product thermac >>"$WORK/build.log" 2>&1
) || { tail -20 "$WORK/build.log" >&2; die "Build failed (log above)."; }
ok "Built"

# --- Install -----------------------------------------------------------------
step "Installing to $APP"
pkill -x ThermacBar 2>/dev/null || true
mkdir -p "$APP_DIR"
(cd "$WORK" && scripts/bundle-app.sh --install >>"$WORK/build.log" 2>&1) \
    || { tail -20 "$WORK/build.log" >&2; die "Packaging failed (log above)."; }
ok "Installed thermac.app"

mkdir -p "$BIN_DIR"
ln -sf "$APP/Contents/MacOS/thermac" "$BIN_DIR/thermac"
ok "Linked the thermac command to $BIN_DIR/thermac"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf '%s  Add it to your PATH to use it from anywhere:  echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc%s\n' "$DIM" "$RESET" ;;
esac

open "$APP"

printf '\n%sthermac is installed.%s\n' "$BOLD" "$RESET"
cat <<EOF
  1. Click the thermometer in the menu bar, then Start Recording.
  2. Let your Mac sleep for 2 hours or more (e.g. overnight).
     The first estimate appears after the first night.

  Uninstall:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --uninstall
EOF
