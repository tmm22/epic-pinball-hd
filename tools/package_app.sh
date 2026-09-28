#!/bin/bash
# Builds a release EpicPinballHD.app (and a .zip) in build/ at the repository root.
#
#   tools/package_app.sh [--bundle-id ID] [--version X.Y] [--no-zip] [--skip-build] [--original DIR]
#
# * Release build of the SwiftPM package in app/ (arm64).
# * Info.plist from app/Resources/Info.plist, icon drawn by app/Resources/make_icon.swift
#   (original artwork) and converted with iconutil.
# * The PinballRender resource bundle (Pinball.metal source) in Contents/Resources.
# * libopenmpt and every non-system dylib it pulls in (mpg123, ogg, vorbis ...) copied to
#   Contents/Frameworks with install names rewritten to @rpath / @loader_path, so the app runs
#   on a Mac without Homebrew. Checked with otool -L afterwards.
# * Ad-hoc code signature (codesign --sign -), verified.
# * Refuses to finish if anything that looks like game data is inside the bundle.
#
# The bundle contains no game data: tables, sounds and texts are read at runtime from the
# user's own files (imported into ~/Library/Application Support/EpicPinballHD/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPDIR="$ROOT/app"
OUT="$ROOT/build"
BUNDLE_ID="com.example.EpicPinballHD"
VERSION="0.1"
ZIP=1
BUILD=1
ORIGINAL="$ROOT/original"   # only read to check that none of the game's texts ended up in the bundle
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle-id) BUNDLE_ID="$2"; shift ;;
        --version) VERSION="$2"; shift ;;
        --no-zip) ZIP=0 ;;
        --skip-build) BUILD=0 ;;
        --original) ORIGINAL="$2"; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="$OUT/EpicPinballHD.app"
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'package_app: error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- build
cd "$APPDIR"
if [ "$BUILD" = 1 ]; then
    say "swift build -c release (arm64)"
    swift build -c release --arch arm64 --product EpicPinball
fi
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
[ -x "$BIN_DIR/EpicPinball" ] || die "no release binary in $BIN_DIR"
RES_BUNDLE="$BIN_DIR/EpicPinball_PinballRender.bundle"
[ -d "$RES_BUNDLE" ] || die "no resource bundle $RES_BUNDLE"

# ---------------------------------------------------------------- bundle layout
say "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/EpicPinball" "$APP/Contents/MacOS/EpicPinball"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    "$APPDIR/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Resource bundle: Contents/Resources (sealed by codesign). The shader source is also copied
# next to it so a lookup through Bundle.main finds it directly.
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
find "$RES_BUNDLE" -name '*.metal' -exec cp {} "$APP/Contents/Resources/" \;

# ---------------------------------------------------------------- icon (original artwork)
say "icon"
ICONSET="$OUT/.icon/AppIcon.iconset"
rm -rf "$OUT/.icon"; mkdir -p "$OUT/.icon"
swift "$APPDIR/Resources/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$OUT/.icon"

# ---------------------------------------------------------------- dylibs
say "embedding non-system dylibs"
FW="$APP/Contents/Frameworks"
is_system() { case "$1" in /usr/lib/*|/System/*) return 0 ;; *) return 1 ;; esac; }
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

# deps FILE -> the dylib load commands (skipping the file's own id line)
deps() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -v "^$(otool -D "$1" | tail -n +2 | head -1)\$" || true; }

# resolve a dependency path (absolute, @rpath/..., @loader_path/...) of FILE to a real file
resolve() {
    local dep="$1" from="$2" name
    name="$(basename "$dep")"
    case "$dep" in
        /*) [ -f "$dep" ] && { echo "$dep"; return; } ;;
        @rpath/*|@loader_path/*|@executable_path/*)
            for d in "$(dirname "$from")" "$BREW_PREFIX/lib" /usr/local/lib; do
                [ -f "$d/$name" ] && { echo "$d/$name"; return; }
            done
            for r in $(otool -l "$from" | awk '/LC_RPATH/{getline; getline; print $2}'); do
                r="${r/@loader_path/$(dirname "$from")}"
                [ -f "$r/$name" ] && { echo "$r/$name"; return; }
            done ;;
    esac
    echo ""
}

QUEUE=("$APP/Contents/MacOS/EpicPinball")
while [ ${#QUEUE[@]} -gt 0 ]; do
    f="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
    for dep in $(deps "$f"); do
        is_system "$dep" && continue
        name="$(basename "$dep")"
        case "$dep" in @rpath/*|@loader_path/*|@executable_path/*)
            [ -f "$FW/$name" ] && continue ;;
        esac
        src="$(resolve "$dep" "$f")"
        [ -n "$src" ] || die "cannot find $dep (needed by $f)"
        if [ ! -f "$FW/$name" ]; then
            cp -L "$src" "$FW/$name"
            chmod u+w "$FW/$name"
            install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
            QUEUE+=("$FW/$name")
            echo "   $name  <- $src"
        fi
        if [ "$f" = "$APP/Contents/MacOS/EpicPinball" ]; then
            install_name_tool -change "$dep" "@rpath/$name" "$f" 2>/dev/null
        else
            install_name_tool -change "$dep" "@loader_path/$name" "$f" 2>/dev/null
        fi
    done
done
EXE="$APP/Contents/MacOS/EpicPinball"
if ! otool -l "$EXE" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
fi
# Drop rpaths into the build machine's Homebrew / build tree.
for r in $(otool -l "$EXE" | awk '/LC_RPATH/{getline; getline; print $2}'); do
    case "$r" in /opt/homebrew/*|/usr/local/*|"$ROOT"/*) install_name_tool -delete_rpath "$r" "$EXE" ;; esac
done

say "otool -L check"
BAD=0
for f in "$EXE" "$FW"/*.dylib; do
    echo "   $(basename "$f"):"
    otool -L "$f" | tail -n +2 | awk '{print "      " $1}'
    if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -Eq '^(/opt/homebrew|/usr/local|'"$ROOT"')'; then
        echo "      ^ still references a non-system absolute path" >&2; BAD=1
    fi
done
[ "$BAD" = 0 ] || die "dylib references outside the bundle remain"

# ---------------------------------------------------------------- no game data
say "checking the bundle for game data"
if find "$APP" -type f \( -iname '*.exe' -o -iname '*.dat' -o -iname '*.pin' -o -iname '*.psm' -o -iname '*.iso' \
        -o -iname '*.npy' -o -iname '*.pcx' -o -iname '*.mus' -o -iname 'playfield*' -o -iname 'palette.json' \
        -o -iname 'engine.json' -o -iname 'rules.json' -o -iname 'sprites.json' -o -iname 'collision*' -o -iname '*.wav' \
        -o -iname '*.png' \) | grep .; then
    die "files that look like game data are in the bundle (listed above)"
fi
# The table names from the user's own ID files must not appear anywhere in the bundle.
if [ -d "$ORIGINAL" ]; then
    for id in "$ORIGINAL"/ID*.DAT; do
        [ -f "$id" ] || continue
        name="$(head -c 20 "$id" | tr -d '\032' | sed 's/ *$//')"
        [ ${#name} -ge 5 ] || continue
        if grep -rqaF "$name" "$APP"; then die "game text '$name' found inside the bundle"; fi
    done
    echo "   no game file types; none of the table names from $ORIGINAL/ID*.DAT occur in the bundle"
else
    echo "   no game file types (no original/ directory to check texts against)"
fi

# ---------------------------------------------------------------- sign
say "ad-hoc codesign"
for f in "$FW"/*.dylib; do codesign --force --sign - --timestamp=none "$f"; done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

# ---------------------------------------------------------------- zip
if [ "$ZIP" = 1 ]; then
    say "zip"
    rm -f "$OUT/EpicPinballHD.zip"
    (cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "EpicPinballHD.app" "EpicPinballHD.zip")
    ls -la "$OUT/EpicPinballHD.zip"
fi
du -sh "$APP"
say "done: $APP"
