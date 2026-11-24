#!/bin/bash
# Build the current version, upload it to Cloudflare R2, rewrite the download
# links, commit, and clean up.
#
# This is the only script that writes release links. Run it by hand for a new
# version; scripts/refresh-release-links.sh calls it when the version changes.
#
# Environment:
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

# --- 2. Upload to Cloudflare R2 ---------------------------------------------------
# R2 is the only host. Keys are versioned and immutable, so a link stays valid
# until the next version - nothing needs a timed refresh. Each publish uploads
# under <prefix>/<version>/, then prunes older versions (keep 2).
R2_ENV=${R2_ENV:-$HOME/.r2.env}
R2_BUCKET=${R2_BUCKET:-torrent-search-covers-eu}
R2_PREFIX=${R2_PREFIX:-keepsake-atelier/releases}
R2_PUBLIC=${R2_PUBLIC:-https://covers.debrid.in}
[ -f "$R2_ENV" ] || die "missing $R2_ENV (R2 S3 keys)"
set -a; . "$R2_ENV"; set +a
for v in R2_S3_ENDPOINT R2_S3_ACCESS_KEY_ID R2_S3_SECRET_ACCESS_KEY; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "$v missing from $R2_ENV"
done
command -v aws >/dev/null 2>&1 || die "aws CLI not found on PATH ($PATH)"
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required

r2_aws() {
  AWS_ACCESS_KEY_ID="$R2_S3_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_S3_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION=auto AWS_EC2_METADATA_DISABLED=true \
    aws "$@" --endpoint-url "$R2_S3_ENDPOINT"
}

r2_put() {  # $1=local file -> prints the public URL
  local key="$R2_PREFIX/$V/$(basename "$1")"
  log "  R2 -> s3://$R2_BUCKET/$key"
  r2_aws s3 cp "$1" "s3://$R2_BUCKET/$key" \
    --content-type application/octet-stream \
    --cache-control 'public, max-age=31536000, immutable' \
    --only-show-errors || return 1
  printf '%s\n' "$R2_PUBLIC/$key"
}

r2_prune() {  # keep the newest $1 versions under the prefix (default 2)
  local keep=${1:-2} versions total
  versions=$(r2_aws s3api list-objects-v2 --bucket "$R2_BUCKET" \
      --prefix "$R2_PREFIX/" --delimiter / \
      --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null \
    | tr '\t' '\n' | sed 's#/$##' | awk -F/ '{print $NF}' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n) || true
  total=$(printf '%s\n' "$versions" | grep -c . || true)
  [ "${total:-0}" -gt "$keep" ] || return 0
  printf '%s\n' "$versions" | sed -n "1,$((total-keep))p" | while IFS= read -r old; do
    log "R2: pruning $R2_PREFIX/$old/"
    r2_aws s3 rm "s3://$R2_BUCKET/$R2_PREFIX/$old/" --recursive --only-show-errors \
      || log "WARNING: R2 prune failed for $old (old objects left in place)"
  done
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

row() {
  grep -v -F "$1 |" "$LINKS" > "$LINKS.tmp" 2>/dev/null || true
  mv "$LINKS.tmp" "$LINKS"
  printf '%s | %s | %s | %s\n' "$1" "$2" "$3" "$4" >> "$LINKS"
}

: > "$LINKS"
for f in "${FILES[@]}"; do
  size=$(human_size "$DIST/$f")
  sha=$(shasum -a 256 "$DIST/$f" | cut -d' ' -f1)
  log "[upload] $f ($size)"
  url=$(r2_put "$DIST/$f") || die "R2 upload failed for $f"
  row "$f" "$url" "$size" "$sha"
done

# --- 3. Rewrite the links -------------------------------------------------------
python3 -I scripts/patch-release-links.py "$LINKS" \
  || die "could not patch the download links"

# --- 4. Commit and push ---------------------------------------------------------
if git diff --quiet -- README.md docs/downloads.json docs/sitemap.xml; then
  log "download links already current - nothing to commit"
else
  git add README.md docs/downloads.json docs/sitemap.xml
  git commit -q -m "docs: publish ${V} downloads to Cloudflare R2

One host, versioned keys: the links stay valid until the next version, so no
weekly mirror refresh is needed any more." || die "git commit failed"
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
log "pruning old R2 versions (keeping the current and previous)"
r2_prune 2

# The rebuild's output is disposable now that R2 has it. An external
# --artifacts directory is left alone, it is not ours to delete.
if [ "${KEEP_DIST:-0}" = "1" ]; then
  log "KEEP_DIST=1: artifacts kept at $DIST"
elif [ -n "$ARTIFACTS" ]; then
  log "artifact directory kept at $DIST"
else
  log "removing local build artifacts"
  rm -rf "$DIST"
  [ -n "$DMG_SRC" ] && rm -f "$DMG_SRC"
fi
notify "Keepsake ${V} downloads published"
log "done"
