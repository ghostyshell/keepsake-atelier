# Publishing builds and download links

Keepsake Atelier ships its builds through Cloudflare R2. Each release lives
under a versioned key (`keepsake-atelier/releases/<version>/<file>`) with a
one-year immutable cache, so a link stays valid until the next release. That is
why there is no timed refresh any more: the scheduled job only checks whether
the repo is ahead of the live feed.

The same pattern is used by the other ghostyshell tools. The pieces are:

- `scripts/publish-release.sh` - build, upload, write the manifest, patch the
  README, commit and clean up.
- `scripts/patch-release-links.py` - turn a `links.txt` manifest into
  `docs/downloads.json` and the README table.
- `scripts/refresh-release-links.sh` - the scheduled entry point: a version
  gate, then the publisher (see `docs/publishing.md`).
- `scripts/install-refresh-job.sh` - write and load the launchd job.
- `docs/downloads.json` - what the GitHub Pages site reads.
- `docs/index.html` - the landing page; its download cards are rendered from the
  JSON.

## One-time setup

1. Put the R2 S3 credentials in `~/.r2.env` (mode 600, never in the repo):

   ```sh
   R2_S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com
   R2_S3_ACCESS_KEY_ID=...
   R2_S3_SECRET_ACCESS_KEY=...
   ```

   The publisher reads that file automatically; `R2_ENV=/path/to/env` points at
   another one. The bucket and prefix default to `torrent-search-covers-eu` and
   `keepsake-atelier/releases`, public at `https://covers.debrid.in`.

2. Confirm the uploader works with a small file:

   ```sh
   set -a; . ~/.r2.env; set +a
   head -c 2048 /dev/urandom > /tmp/test.bin
   AWS_ACCESS_KEY_ID=$R2_S3_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY=$R2_S3_SECRET_ACCESS_KEY \
   AWS_DEFAULT_REGION=auto aws s3 cp /tmp/test.bin \
     "s3://torrent-search-covers-eu/pilot/test.bin" \
     --endpoint-url "$R2_S3_ENDPOINT" --only-show-errors
   curl -fsS https://covers.debrid.in/pilot/test.bin >/dev/null && echo ok
   ```

3. Install the app bundler used by the DMG step:

   ```sh
   brew install dylibbundler
   ```

4. Make the scripts executable:

   ```sh
   chmod +x scripts/publish-release.sh scripts/refresh-release-links.sh \
            scripts/install-refresh-job.sh scripts/bundle-app.sh
   ```

## Build and upload

```sh
scripts/publish-release.sh
```

What it does, in order:

1. Reads the version from `app/src-tauri/tauri.conf.json`.
2. Builds the `.app`, bundles libbluray/libaacs/libbdplus and their dependencies
   with `scripts/bundle-app.sh` (dylibbundler, ad-hoc signing), creates the DMG
   with `hdiutil`, and builds the CLI tarball into `dist/`.
3. Uploads each artifact to `keepsake-atelier/releases/<version>/` on R2.
4. Writes `.release-<version>-<date>/links.txt`, recording
   `name | url | size | sha256`.
5. Regenerates `docs/downloads.json` and the README download table.
6. Commits and pushes the link update.
7. Prunes every older R2 version except the current and the previous one, then
   deletes the local `dist/` artifacts. An `--artifacts` directory is left alone.

Environment switches:

- `R2_ENV` - path to the credentials file (default `~/.r2.env`).
- `KEEPSAKE_REPO` - run against another checkout.
- `SKIP_PUSH=1` - commit locally and stop before `git push`.
- `KEEP_DIST=1` - do not delete `dist/` after a successful upload.

## Cross-platform artifacts

The macOS arm64 DMG and CLI are built locally. Intel macOS, Linux and Windows are
built by the GitHub Actions matrix:

```sh
gh workflow run build.yml -f platforms=all       # or macos, linux, windows
gh run watch
gh run download <run-id> -D /tmp/ci-all
```

The workflow stores one artifact directory per platform:

- `macos-arm64` / `macos-x64`: `Keepsake-Atelier-<v>-arm64.dmg`,
  `Keepsake-Atelier-<v>-x64.dmg`, and a `macos-<arch>` CLI tarball.
- `linux-x64`: `keepsake-atelier-<v>-linux-x64.tar.gz`.
- `windows-x64`: `keepsake-atelier-<v>-windows-x64.zip` (exe plus the MSYS2
  runtime DLLs).

Publish a downloaded set without rebuilding the macOS arm64 side:

```sh
mkdir -p /tmp/ci-flat
find /tmp/ci-all -type f \( -name '*.dmg' -o -name '*.tar.gz' -o -name '*.zip' \) \
  -exec cp {} /tmp/ci-flat/ \;
scripts/publish-release.sh --artifacts /tmp/ci-flat
```

`--artifacts` skips the build, uploads each file, rewrites the manifest and the
README, commits and pushes. The patcher merges by **artifact identity** (kind,
OS, arch), so a same-version row it did not rebuild survives; a local macOS run
cannot drop the Linux or Windows links. Older-version rows are discarded.

Run the workflow again when you bump the version so every platform is
regenerated; R2 keys are immutable, so never re-upload different bytes at an
existing version.

## The scheduled check

```sh
scripts/refresh-release-links.sh
```

The wrapper reads the version from the config and the version in the live
`https://ghostyshell.github.io/keepsake-atelier/downloads.json`. When they match
it exits without doing anything; `FORCE=1` publishes anyway. The publisher takes
a lock so two runs cannot overlap and logs to `.release-refresh.log`.

It does not bump the version: a release is a deliberate version change, and an
R2 link needs no renewal in between.

## Install the scheduled job

```sh
scripts/install-refresh-job.sh
```

This writes `~/Library/LaunchAgents/click.keepsakeatelier.weekly-refresh.plist`
and loads it. The default is Sunday at 03:47 under `caffeinate -i`, so the Mac
does not sleep in the middle of an upload.

Options:

```sh
scripts/install-refresh-job.sh --time 04:15 --weekday 1
scripts/install-refresh-job.sh --repo /path/to/keepsake-atelier
scripts/install-refresh-job.sh --uninstall
```

launchd gets a thin `PATH`. The installer writes the current `PATH` plus
`/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.cargo/bin` and `$HOME/.local/bin`
into the plist, so `node`, `npx`, `cargo`, `caffeinate` and `gh` are found.

### Running it on the MacBook Air

The job is a normal launchd user agent, so it can live on any Mac that has the
checkout and `~/.r2.env`. On the Air:

1. Clone the repo to the same absolute path, or pass `--repo` when installing.
2. Copy `~/.r2.env` over (scp; keep mode 600).
3. Make sure `node`, `npx`, `cargo`, the `aws` CLI and the Rust toolchain are
   installed.
4. Run `scripts/install-refresh-job.sh --repo /absolute/path`.

The job writes the repository, so the Air needs push access to
`origin/main` and an active `gh` account with the ghostyshell identity.

## What the manifest looks like

`.release-0.1.0-20261111/links.txt`:

```
Keepsake-Atelier-0.1.0-arm64.dmg | https://covers.debrid.in/keepsake-atelier/releases/0.1.0/Keepsake-Atelier-0.1.0-arm64.dmg | 32.1 MiB | 9f2c...
keepsake-atelier-0.1.0-arm64.tar.gz | https://covers.debrid.in/keepsake-atelier/releases/0.1.0/keepsake-atelier-0.1.0-arm64.tar.gz | 8.4 MiB | 1a3b...
```

`docs/downloads.json` is generated from it and read by the site at runtime:

```json
{
  "version": "0.1.0",
  "updated": "2026-11-11",
  "artifacts": [
    {
      "label": "macOS (Apple Silicon)",
      "name": "Keepsake-Atelier-0.1.0-arm64.dmg",
      "url": "https://covers.debrid.in/keepsake-atelier/releases/0.1.0/Keepsake-Atelier-0.1.0-arm64.dmg",
      "size": "32.1 MiB",
      "sha256": "9f2c..."
    }
  ]
}
```

## README and site

The README carries a generated block between `<!-- downloads:start -->` and
`<!-- downloads:end -->`. Do not hand-edit inside it; the publisher replaces it.

The site reads `downloads.json` with `cache: no-store` and falls back to a static
card if the file is missing. That means a link refresh is a data change, not an
HTML change.

## Security notes

- The R2 credentials in `~/.r2.env` and any `gh` credentials stay on the
  machine that runs the job. They are never committed.
- The publisher only uploads `dist/` artifacts it just built. It does not walk
  arbitrary folders.
- The job commits only `README.md`, `docs/downloads.json` and `docs/sitemap.xml`.
- Pruning runs after the docs are written, and it deletes only versioned
  `keepsake-atelier/releases/<version>/` prefixes, never the current two.
- Review `git diff` after the first run before trusting the job unattended.
