#!/bin/bash
# Builds a release EpicPinballHD.app (and a .zip) in build/ at the repository root.
#
#   tools/package_app.sh [--bundle-id ID] [--version X.Y] [--no-zip] [--skip-build] [--original DIR]
#                        [--scratch-path DIR] [--no-run-check] [--lenient] [--iso FILE] [--keep-check DIR]
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
# * Runtime check (skip with --no-run-check): the packaged binary is started with
#   DYLD_PRINT_LIBRARIES and must load no dylib from Homebrew or the build tree. Then, under
#   sandbox-exec with extracted/, the build trees and .venv unreadable (and original/ too when a
#   CD image is used) and python not executable, and with the build tree's resource bundle moved
#   away, it imports your CD image (--iso, default the first *.iso in the repo root; else original/)
#   into a fresh support dir with --headless-import, plays a game to game over with --autoplay
#   (table 1 classic physics, table 10 enhanced physics) and renders an xbrz + lighting --snapshot
#   from that library. A failure stops the script before the zip (--lenient: warning only).
#
# The bundle contains no game data: tables, sounds and texts are read at runtime from the
# user's own files (imported into ~/Library/Application Support/EpicPinballHD/).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"   # physical path: dyld and otool report resolved paths
APPDIR="$ROOT/app"
OUT="$ROOT/build"
BUNDLE_ID="com.example.EpicPinballHD"
VERSION="0.1"
ZIP=1
BUILD=1
ORIGINAL="$ROOT/original"   # only read to check that none of the game's texts ended up in the bundle
SCRATCH=""                  # --scratch-path for swift build (a private build dir; default app/.build)
RUN_CHECK=1
STRICT=1                    # a failed runtime check stops the script before the zip (--lenient: warn only)
ISO=""                      # --iso FILE: the CD image the runtime check imports (default: the first *.iso in the repo root)
KEEP_CHECK=""               # --keep-check DIR: keep the runtime check's outputs (import log, reports, snapshot)
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle-id) BUNDLE_ID="$2"; shift ;;
        --version) VERSION="$2"; shift ;;
        --no-zip) ZIP=0 ;;
        --skip-build) BUILD=0 ;;
        --original) ORIGINAL="$2"; shift ;;
        --scratch-path) SCRATCH="$2"; shift ;;
        --no-run-check) RUN_CHECK=0 ;;
        --strict) STRICT=1 ;;
        --lenient) STRICT=0 ;;
        --iso) ISO="$2"; shift ;;
        --keep-check) KEEP_CHECK="$2"; shift ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
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
SWIFT_FLAGS=(-c release --arch arm64)
[ -n "$SCRATCH" ] && SWIFT_FLAGS+=(--scratch-path "$SCRATCH")
if [ "$BUILD" = 1 ]; then
    say "swift build ${SWIFT_FLAGS[*]}"
    swift build "${SWIFT_FLAGS[@]}" --product EpicPinball
fi
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)"
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
# Compile rather than interpret: the swift.org toolchains' script JIT does not load AppKit
# (NSBitmapImageRep symbols not found), while a compiled binary links it on every toolchain.
swiftc -O -o "$OUT/.icon/make_icon" "$APPDIR/Resources/make_icon.swift"
"$OUT/.icon/make_icon" "$ICONSET" >/dev/null
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
# Drop rpaths into the build machine's Homebrew, build tree or Xcode toolchain (the binary loads
# nothing through them: its only @rpath dependency is libopenmpt, now in Contents/Frameworks).
if otool -L "$EXE" | tail -n +2 | awk '{print $1}' | grep '^@rpath/' | grep -qv '^@rpath/lib\(openmpt\|mpg123\|ogg\|vorbis\|vorbisfile\)'; then
    echo "   note: other @rpath dependencies present, keeping toolchain rpaths"; KEEP_TOOLCHAIN=1
else
    KEEP_TOOLCHAIN=0
fi
for r in $(otool -l "$EXE" | awk '/LC_RPATH/{getline; getline; print $2}'); do
    case "$r" in
        /opt/homebrew/*|/usr/local/*|"$ROOT"/*) install_name_tool -delete_rpath "$r" "$EXE" ;;
        /Applications/Xcode*.app/*|/Library/Developer/*) [ "$KEEP_TOOLCHAIN" = 0 ] && install_name_tool -delete_rpath "$r" "$EXE" ;;
    esac
done
echo "   rpaths: $(otool -l "$EXE" | awk '/LC_RPATH/{getline; getline; printf "%s ", $2}')"

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

# ---------------------------------------------------------------- runtime check
RUN_OK=1
if [ "$RUN_CHECK" = 1 ]; then
    say "runtime check"
    TMPC="$(cd "$(mktemp -d)" && pwd -P)"
    # 1. every dylib the binary loads is a system library or one of Contents/Frameworks
    DYLD_PRINT_LIBRARIES=1 "$EXE" --help >/dev/null 2>"$TMPC/dyld.txt" || true
    LOADED="$(grep -Eo '(/[^ ]+\.dylib|/[^ ]+/Frameworks/[^ ]+)' "$TMPC/dyld.txt" | sort -u || true)"
    OUTSIDE="$(echo "$LOADED" | grep -vF "$APP/Contents/Frameworks/" | grep -E '^(/opt/homebrew|/usr/local|'"$ROOT"')' || true)"
    INSIDE="$(echo "$LOADED" | grep -c "^$APP/Contents/Frameworks/" || true)"
    if [ -n "$OUTSIDE" ]; then
        echo "   FAIL: loaded from outside the bundle:"; echo "$OUTSIDE" | sed 's/^/      /'; RUN_OK=0
    else
        echo "   dylibs: $INSIDE loaded from Contents/Frameworks, none from Homebrew or the build tree"
    fi
    # 2. as on a Mac that has never built the app and has no Python: the packaged binary imports
    #    the user's CD (or original/ folder) with the Swift importer into a fresh support dir, then
    #    plays and renders from that library. It runs under sandbox-exec with the developer data
    #    (extracted/, original/), the build trees and the Python venv unreadable and python not
    #    executable; the build tree's resource bundle is also moved away.
    SRC="$ISO"
    [ -n "$SRC" ] || SRC="$(ls "$ROOT"/*.iso 2>/dev/null | head -1 || true)"
    [ -n "$SRC" ] || { [ -f "$ORIGINAL/EP1.EXE" ] && SRC="$ORIGINAL"; }
    if [ -n "$SRC" ]; then
        SUPPORT="$TMPC/support"
        PROFILE="$TMPC/no-dev-data.sb"
        {
            echo '(version 1)'
            echo '(allow default)'
            printf '(deny file-read* (subpath "%s/extracted") (subpath "%s/.venv") (subpath "%s/.build") (subpath "%s")' "$ROOT" "$ROOT" "$APPDIR" "$BIN_DIR"
            [ "$SRC" != "$ORIGINAL" ] && printf ' (subpath "%s")' "$ORIGINAL"
            echo ')'
            echo '(deny process-exec (regex #"python"))'
        } > "$PROFILE"
        HIDDEN="$RES_BUNDLE.hidden-by-package-app"
        mv "$RES_BUNDLE" "$HIDDEN"
        trap 'mv "$HIDDEN" "$RES_BUNDLE" 2>/dev/null || true' EXIT
        run() { env -u EPIC_PINBALL_DATA -u EPIC_PINBALL_ORIGINAL -u EPIC_PINBALL_RULES -u EPIC_PINBALL_RENDER \
                    sandbox-exec -f "$PROFILE" "$EXE" --support-dir "$SUPPORT" "$@"; }
        if ! sandbox-exec -f "$PROFILE" ls "$ROOT/extracted" >/dev/null 2>&1; then
            echo "   sandbox: extracted/, .venv, the build trees$( [ "$SRC" != "$ORIGINAL" ] && echo ', original/') unreadable; python not executable"
        fi
        if run --headless-import "$SRC" >"$TMPC/import.txt" 2>&1; then
            echo "   import: $(tail -1 "$TMPC/import.txt" | cut -c1-110)..."
        else
            echo "   FAIL: import from $SRC:"; tail -5 "$TMPC/import.txt" | sed 's/^/      /'; RUN_OK=0
        fi
        if [ -f "$SUPPORT/Library/rules.json" ] || ls "$SUPPORT"/Library/tables/*/rules.json >/dev/null 2>&1; then
            echo "   FAIL: the library contains rules.json (should run the rules from the EXE)"; RUN_OK=0
        fi
        for spec in "1 classic" "10 enhanced"; do
            set -- $spec
            if run --table "$1" --physics "$2" --autoplay 60000 --json "$TMPC/auto$1.json" >/dev/null 2>"$TMPC/auto$1.err" \
                    && grep -q '"gameOver" : true' "$TMPC/auto$1.json" && grep -q '"rulesBackend" : "direct"' "$TMPC/auto$1.json"; then
                echo "   autoplay table $1 ($2 physics): game over, score $(awk -F': ' '/"score"/{gsub(/,/,"",$2); print $2}' "$TMPC/auto$1.json"), rules direct from the imported EXE"
            else
                echo "   FAIL: autoplay table $1 ($2 physics):"; tail -3 "$TMPC/auto$1.err" "$TMPC/auto$1.json" 2>/dev/null | sed 's/^/      /'; RUN_OK=0
            fi
        done
        if run --library "$SUPPORT/Library" --table 1 --snapshot "$TMPC/snap.png" --launch --sim-time 1 --filter xbrz --lighting subtle \
                >"$TMPC/snap.txt" 2>&1 && [ -s "$TMPC/snap.png" ] && ! grep -q "not found" "$TMPC/snap.txt"; then
            echo "   snapshot (xbrz + lighting) rendered from the library: $(sips -g pixelWidth -g pixelHeight "$TMPC/snap.png" | awk '/pixel/{printf "%s ", $2}')px"
        else
            echo "   FAIL: snapshot from the imported library:"; tail -3 "$TMPC/snap.txt" | sed 's/^/      /'; RUN_OK=0
        fi
        if [ -n "$KEEP_CHECK" ]; then rm -rf "$KEEP_CHECK"; mkdir -p "$KEEP_CHECK"; cp "$TMPC"/*.txt "$TMPC"/*.json "$TMPC"/*.png "$TMPC"/*.err "$KEEP_CHECK"/ 2>/dev/null || true; echo "   check outputs kept in $KEEP_CHECK"; fi
        mv "$HIDDEN" "$RES_BUNDLE"; trap - EXIT
    else
        echo "   (no CD image or original/ folder: import/play check skipped)"
    fi
    rm -rf "$TMPC"
    if [ "$RUN_OK" = 0 ]; then
        [ "$STRICT" = 1 ] && die "runtime check failed (use --lenient to package anyway)"
        printf '\033[1;33mpackage_app: warning: runtime check failed (see above); the app may not run on other Macs\033[0m\n' >&2
    fi
fi

# ---------------------------------------------------------------- zip
if [ "$ZIP" = 1 ]; then
    say "zip"
    rm -f "$OUT/EpicPinballHD.zip"
    (cd "$OUT" && ditto -c -k --sequesterRsrc --keepParent "EpicPinballHD.app" "EpicPinballHD.zip")
    ls -la "$OUT/EpicPinballHD.zip"
fi
du -sh "$APP"
say "done: $APP"
