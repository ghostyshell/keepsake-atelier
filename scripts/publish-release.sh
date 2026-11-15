#!/bin/bash
# Build the current version, upload it to GoFile and file.kiwi, rewrite the
# download links, commit and clean up.
#
# This is the only script that writes release links. Run it by hand for a new
# version, or let scripts/refresh-release-links.sh call it weekly to renew the
# free-tier mirrors.
#
# Environment:
#   GOFILE_TOKEN       token string; overrides .gofile-io-token
#   KEEPSAKE_REPO      repository to operate on (default: this checkout)
#   SKIP_PUSH=1        commit but do not push
#   KEEP_DIST=1        keep dist/ after a fully successful upload
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)
REPO=${KEEPSAKE_REPO:-$(cd "$SELF/.." && pwd)}
cd "$REPO"

ARTIFACTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ARTIFACTS=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { log "FAILED: $*"; exit 1; }
notify() { osascript -e "display notification \"$1\" with title \"Keepsake release\"" >/dev/null 2>&1 || true; }

for tool in python3 curl git shasum tar; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH ($PATH)"
done
command -v npx >/dev/null 2>&1 || die "npx not found on PATH ($PATH)"

V=$(python3 - <<'PY'
import json
print(json.load(open("app/src-tauri/tauri.conf.json"))["version"])
PY
)
[ -n "$V" ] || die "could not read the version from app/src-tauri/tauri.conf.json"

RUN=".release-${V}-$(date +%Y%m%d)"
LINKS="$RUN/links.txt"
DIST="dist"
mkdir -p "$RUN" "$DIST"
touch "$LINKS"

# One run at a time. A slept-through slot must not start a second upload.
LOCK=.release-publish.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    log "another publish is already running (pid $pid) - exiting"
    exit 0
  fi
  log "clearing stale lock (pid ${pid:-unknown} is not running)"
  rm -rf "$LOCK"
  mkdir "$LOCK"
fi
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# Old run directories are text and logs only. Keep a month.
find . -maxdepth 1 -name '.release-*' -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true

TOKEN=${GOFILE_TOKEN:-$(cat "$REPO/.gofile-io-token" 2>/dev/null || true)}
[ -n "$TOKEN" ] || die "no GoFile token: write .gofile-io-token or set GOFILE_TOKEN"

log "publishing Keepsake Atelier $V"

# --- 1. Build (or take a directory from CI) -------------------------------------
if [ -n "$ARTIFACTS" ]; then
  [ -d "$ARTIFACTS" ] || die "no artifact directory at $ARTIFACTS"
  DIST=$(cd "$ARTIFACTS" && pwd)
  FILES=()
  for f in "$DIST"/*.dmg "$DIST"/*.tar.gz "$DIST"/*.zip "$DIST"/*.AppImage "$DIST"/*.deb "$DIST"/*.exe; do
    if [ -f "$f" ]; then FILES+=("$(basename "$f")"); fi
  done
  [ ${#FILES[@]} -gt 0 ] || die "no dmg/tar.gz/zip files in $DIST"
  DMG_SRC=""
  log "using existing artifacts: ${FILES[*]}"
else
  # Match CI's macos-arm64 job: the published artifacts must carry the
  # vendored, macOS 12-targeted disc stack. A Homebrew-linked build looks
  # fine here and refuses to launch on macOS 12/13, so it never ships.
  BLURAY_PREFIX="$REPO/vendor/disc/prefix"
  export BLURAY_PREFIX
  export MACOSX_DEPLOYMENT_TARGET=12.0
  [ -f "$BLURAY_PREFIX/lib/libbluray.dylib" ] || {
    log "building the vendored disc libraries"
    "$REPO/scripts/build-disc-libs.sh" >> "$RUN/build.log" 2>&1 \
      || die "build-disc-libs failed - see $RUN/build.log"
  }
  for res in ffmpeg ffprobe 00000.jar ffmpeg-LICENSES.txt; do
    [ -f "$REPO/app/src-tauri/resources/$res" ] && continue
    log "building ffmpeg and the app resources"
    "$REPO/scripts/build-ffmpeg.sh" >> "$RUN/build.log" 2>&1 \
      || die "build-ffmpeg failed - see $RUN/build.log"
    break
  done

  log "building the app"
  rm -f "$DIST"/*.dmg "$DIST"/*.tar.gz
  ( cd app && npx tauri build --bundles app \
      --config '{"bundle":{"createUpdaterArtifacts":false}}' ) \
    >> "$RUN/build.log" 2>&1 || die "tauri build failed - see $RUN/build.log"

  APP=$(ls -d "$REPO"/target/release/bundle/macos/*.app 2>/dev/null | head -1)
  [ -n "$APP" ] || die "the build did not produce an app bundle"
  otool -L "$APP/Contents/MacOS/keepsake-atelier-app" \
    | grep -q "vendor/disc/prefix/lib/libbluray" \
    || die "the app linked Homebrew libbluray, not the vendored one"
  "$REPO/scripts/bundle-app.sh" "$APP" >> "$RUN/build.log" 2>&1 \
    || die "dylib bundling failed - see $RUN/build.log"

  log "building the CLI"
  cargo build --release --target aarch64-apple-darwin -p keepsake-atelier \
    >> "$RUN/build.log" 2>&1 || die "cargo build failed - see $RUN/build.log"

  DMG_NAME="Keepsake-Atelier-${V}-arm64.dmg"
  CLI_NAME="keepsake-atelier-${V}-macos-arm64.tar.gz"

  "$REPO/scripts/make-dmg.sh" "$APP" "Keepsake Atelier" "$DIST/$DMG_NAME" \
    "$REPO/app/src-tauri/dmg-background.png" >> "$RUN/build.log" 2>&1 \
    || die "installer DMG failed - see $RUN/build.log"

  # The same self-contained payload as CI: the binary with rewritten dylibs,
  # the dlopen'ed AACS/BD+ stack, ffmpeg, ffprobe and the menu JAR.
  "$REPO/scripts/bundle-cli.sh" \
    "$REPO/target/aarch64-apple-darwin/release/keepsake-atelier" \
    "$RUN/cli" "$REPO/app/src-tauri/resources" >> "$RUN/build.log" 2>&1 \
    || die "cli bundling failed - see $RUN/build.log"
  tar -czf "$DIST/$CLI_NAME" -C "$RUN/cli" \
    keepsake-atelier lib ffmpeg ffprobe 00000.jar ffmpeg-LICENSES.txt

  # Refuse to publish what CI would reject: every shipped binary and dylib
  # must target macOS 12.0.
  for f in "$APP/Contents/MacOS/keepsake-atelier-app" \
           "$APP/Contents/Resources/lib/"*.dylib \
           "$RUN/cli/keepsake-atelier" "$RUN/cli/ffmpeg" "$RUN/cli/ffprobe" \
           "$RUN/cli/lib/"*.dylib; do
    m=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{v=1} v&&/minos/{print $2; exit}')
    [ "$m" = "12.0" ] || die "$f carries minos $m, not 12.0 - see $RUN/build.log"
  done

  FILES=("$DMG_NAME" "$CLI_NAME")
  DMG_SRC=""
  log "built: ${FILES[*]}"
fi

# --- 2. Upload ------------------------------------------------------------------
field() { grep -F "$1 |" "$LINKS" 2>/dev/null | tail -1 | cut -d'|' -f"$2" | sed 's/^ *//;s/ *$//' || true; }
row() {
  grep -v -F "$1 |" "$LINKS" > "$LINKS.tmp" 2>/dev/null || true
  mv "$LINKS.tmp" "$LINKS"
  printf '%s | %s | %s | %s | %s\n' "$1" "$2" "$3" "$4" "$5" >> "$LINKS"
}

human_size() {
  python3 - "$1" <<'PY'
import os, sys
b = os.path.getsize(sys.argv[1])
for unit in ("B", "KiB", "MiB", "GiB"):
    if b < 1024 or unit == "GiB":
        print(f"{b:.1f} {unit}" if unit != "B" else f"{b} B")
        break
    b /= 1024.0
PY
}

put_gofile() {
  local f=$1 url=""
  for attempt in 1 2 3; do
    url=$(curl -sS --max-time 3600 -X POST \
      "https://upload.gofile.io/contents/uploadfile" \
      -H "Authorization: Bearer $TOKEN" \
      -F "file=@$DIST/$f" 2>/dev/null \
      | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("data", {}).get("downloadPage", ""))
except Exception:
    print("")' 2>/dev/null) || url=""
    if [ -n "$url" ]; then printf '%s\n' "$url"; return 0; fi
    log "  gofile attempt $attempt/3 failed for $f; retrying in 30s"
    sleep 30
  done
  return 1
}

put_kiwi() {
  FORCE_COLOR=0 npx -y @file-kiwi/node "$DIST/$1" --title "$1" 2>&1 \
    | grep -Eo 'https://file\.kiwi/[A-Za-z0-9][A-Za-z0-9#_+/=-]*' | tail -1 || true
}

incomplete=0
for f in "${FILES[@]}"; do
  gf=$(field "$f" 2)
  kw=$(field "$f" 3)
  if [ -n "$gf" ] && [ "$gf" != "EMPTY" ] && [ -n "$kw" ] && [ "$kw" != "EMPTY" ]; then
    log "[skip] $f already uploaded today"
    continue
  fi
  size=$(human_size "$DIST/$f")
  sha=$(shasum -a 256 "$DIST/$f" | cut -d' ' -f1)
  log "[start] $f ($size)"
  if [ -z "$gf" ] || [ "$gf" = "EMPTY" ]; then
    gf=$(put_gofile "$f") || gf="EMPTY"
  fi
  if [ -z "$kw" ] || [ "$kw" = "EMPTY" ]; then
    kw=$(put_kiwi "$f")
  fi
  [ -n "$gf" ] && [ "$gf" != "EMPTY" ] || incomplete=1
  [ -n "$kw" ] && [ "$kw" != "EMPTY" ] || incomplete=1
  log "[done] $f | ${gf:-EMPTY} | ${kw:-EMPTY}"
  row "$f" "${gf:-EMPTY}" "${kw:-EMPTY}" "$size" "$sha"
done

# --- 3. Rewrite the links -------------------------------------------------------
python3 -I scripts/patch-release-links.py "$LINKS" \
  || die "could not patch the download links"

# --- 4. Commit and push ---------------------------------------------------------
if git diff --quiet -- README.md docs/downloads.json docs/sitemap.xml; then
  log "download links already current - nothing to commit"
else
  git add README.md docs/downloads.json docs/sitemap.xml
  git commit -q -m "docs: refresh ${V} download links (GoFile + file.kiwi)

Automated weekly refresh: the current version is rebuilt and re-uploaded to
GoFile (primary) and file.kiwi (backup). Free-tier links expire, so the docs
are repointed at the fresh mirrors." || die "git commit failed"
  if [ "${SKIP_PUSH:-0}" = "1" ]; then
    log "SKIP_PUSH=1: links committed locally; not pushed"
  else
    command -v gh >/dev/null 2>&1 && gh auth switch --user ghostyshell >/dev/null 2>&1 || true
    git -c credential.helper='!gh auth git-credential' push -q origin main \
      || die "git push failed - links are committed locally but not published"
    log "pushed refreshed ${V} links"
    # A tag marks what has actually shipped; check-changelog.sh uses it as its
    # baseline so a version is never reused.
    git tag -f "v${V}" >/dev/null 2>&1 || true
    git -c credential.helper='!gh auth git-credential' push -q -f origin "v${V}" >/dev/null 2>&1 || true
  fi
fi

# --- 5. Clean up ----------------------------------------------------------------
if [ "$incomplete" -ne 0 ]; then
  log "WARNING: at least one mirror is missing - dist/ kept so a re-run can finish"
  notify "Keepsake ${V} refresh finished with gaps"
else
  if [ "${KEEP_DIST:-0}" = "1" ]; then
    log "KEEP_DIST=1: dist/ kept"
  else
    if [ -n "$ARTIFACTS" ]; then
      log "artifact directory kept at $DIST"
    else
      log "removing local build artifacts"
      rm -rf "$DIST"
      [ -n "$DMG_SRC" ] && rm -f "$DMG_SRC"
    fi
  fi
  notify "Keepsake ${V} download links refreshed"
fi

log "done"
