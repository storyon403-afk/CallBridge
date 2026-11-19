# Packaging and Uploading

Current stable release: **0.0.4 / build 50**, tag **v0.0.4**, Apple Silicon/macOS 26+ and Windows 11 x64. Apple distribution signing/notarization and Windows publisher signing are deferred; retain those disclosures in downloads.

0.0.4 was promoted after Windows-to-Mac WebRTC audio/video and a signed Sparkle upgrade from 0.0.3 passed. The original 12 attachments are immutable. The recommended Windows download is the supplemental `CallBridge-0.0.4-windows-x64-icons1.zip` with `WINDOWS-icons1-SHA256SUMS`; only the application EXE and DLL changed within its payload. The procedures below describe how the original candidate was created. Do not re-run them to replace existing assets or revert the release to pre-release.

## Generate packages

Prepare tools using [source build](GETTING_STARTED.md#build-from-source), then run from root:

```sh
python3 scripts/prepare-sparkle.py
sh rust/scripts/build-app.sh
python3 scripts/prepare-release-runtime.py
python3 scripts/package-release.py
python3 scripts/check-release.py
```

`rust/build/releases/0.0.4/` contains macOS and Windows ZIPs, source archive, manifests, signed `appcast.xml`, `SHA256SUMS`. Stage only the 12 final attachments listed below into `github-release/`; never include old `ui1`/`ui2` test packages. App ZIP includes Node, excluding personal recordings/voices/settings/speech models. Users install virtual audio/OBS separately. Source only: `python3 scripts/package-release.py --source-only`.

## Windows release payload

The 0.0.4 Windows test package is rebuilt from current source using `sh rust/scripts/build-windows-cross.sh`. It does not reuse the accepted 0.0.3 ui2 executables. The manifest records `windows_execution_verified=false`; perform the packaged Windows acceptance checklist before considering a stable release. Keep historical accepted packages unchanged.

`python3 scripts/check-windows.py` verifies archive contents and dependencies; `python3 scripts/package-release.py` includes the Windows ZIP and `WINDOWS-SHA256SUMS` in the combined checksum file. These checks do not execute Windows UI or devices.

For runtime acceptance, compare the ZIP digest with the published `SHA256SUMS` and extract it to a fresh directory. On macOS, run `CallBridge.app/Contents/MacOS/CallBridge --ui-smoke` from a writable scratch directory (use the absolute path to the extracted executable). Then run the repository's `scripts/check-packaged-video.mjs` with the **extracted** `CallBridge.app/Contents/MacOS/node` or, on Windows, `runtime\node.exe`. The script checks the packaged page assets, passes one synthetic 720p frame through the packaged host and worker in memory, and verifies stop and exit. It never opens a device. On Windows, also run `Test-Windows.cmd` and the packaged `UI-ACCEPTANCE.md`; record the package digest, Windows build, log and observed results before promoting the release.

## GitHub upload scope

Include source, build scripts, usage, licenses, `plugins/official/`, website assets, `SECURITY.md`, `THIRD_PARTY_NOTICES.md`. Keep `website/media/`, `assets/demos/`, `assets/diagrams/04.png` required by the site. Exclude `build/`, `target/`, `node_modules/`, `__pycache__/`, `plugins/experimental/`, personal recordings/voices/settings. Experimental artwork has no confirmed redistribution clearance and remains local; do not commit or attach it. Generated `UPLOAD_FILES.txt` lists source contents.

## Historical: original pre-release publication

1. Commit/push prepared source.
2. Create a **draft pre-release** GitHub Release for **v0.0.4**, title **CallBridge 0.0.4 — Test release**, targeting the pushed commit.
3. Use [release notes](release/NOTES.md), also copied as `RELEASE_NOTES.md` in the final attachment folder.
4. Attach **all 12 files** from `rust/build/releases/0.0.4/github-release/`: both platform ZIPs, source archive, `APP_MANIFEST.json`, `SOURCE_MANIFEST.json`, `UPLOAD_FILES.txt`, `SHA256SUMS`, `WINDOWS-SHA256SUMS`, `appcast.xml`, `GETTING_STARTED.md`, `SECURITY.md` and `RELEASE_NOTES.md`.
5. Review the attachments, retain signing/notarization disclosures, then publish the draft as a **pre-release**, with `latest=false`. Keep v0.0.3 as the stable latest release. A Git push alone does not upload binaries or publish a GitHub Release.

Scripts generate files only, without automatic commit/push/publication. These steps require explicit authorization.

## Publish official plugins

```sh
python3 scripts/package-official-plugins.py
```

Upload three `.cbplugin`, `SHA256SUMS`, `LICENSE` from `build/official-plugins/plugins-v1/` to separate **plugins-v1** Release. Do not track archives. Once downloadable:

```sh
python3 scripts/package-official-plugins.py --verify-published
```

This checks bytes and updates `plugins/official/catalog.json`. Review/commit/push the catalog; App refresh then exposes downloads. See [official plugins](plugins/official/README.md).

## Update website

The existing `.github/workflows/pages.yml` deploys only matching website paths on `main`. This test release does not modify website assets or workflow configuration. Preview instructions: [website guide](website/README.md).

## Automatic update release contract

Sparkle is pinned by `release/sparkle.json`. Prepare it explicitly before the offline build. Development bundles set `CBEnableUpdates=false`; packaging enables it only in the staged release bundle. Diagnostic modes never initialize the updater. Release defaults enable checks every 86,400 seconds, automatic downloads, and installation on quit. No LaunchAgent is installed. Users can change the automatic-update preference from either menu.

The feed URL is `https://github.com/storyon403-afk/CallBridge/releases/latest/download/appcast.xml`. Every stable release must attach the generated `appcast.xml` **and** its corresponding App ZIP before it is designated GitHub's latest release. Use a draft release to upload all attachments first. Prereleases and plugin-only releases must not replace the latest stable App release. The feed references the immutable version tag, not the latest ZIP URL. Retain past App attachments. Future releases must increase the numeric `CFBundleVersion` as well as update the public version. Never reuse a published build number or replace a published archive.

Packaging uses Sparkle's `generate_appcast` and the macOS Keychain account `dev.callbridge.demo`. It checks that the account's public key matches `SUPublicEDKey` before signing. The private key is stored only in the maintainer's login Keychain; it is not exported into the repository, build output, or App. Back up that key securely before publishing the first updater-enabled release, and restore the same key when moving release machines. A missing/mismatched key stops packaging; do not generate a replacement key for an existing update channel. Source-only packaging needs no signing key.

Both feed and archive signatures are required; feed-validation failures never expire into unsigned fallback. `scripts/check-release.py` verifies those signatures, exact version/build/OS/download URL/length, packaged defaults, framework links, and payload hashes. The archive must not be changed after signing. SHA256SUMS includes the final signed feed. Publish only after these checks pass. The updater does not install drivers, models, or plugins. Gatekeeper, writable-location requirements, and Apple signing/notarization remain separate constraints. A system authorization prompt can prevent fully unattended installation in protected locations.

Versions through 0.0.2 have no updater and require one manual installation of 0.0.3 or later. Publishing files does not retrofit older clients. Local preparation does not publish a GitHub release.
