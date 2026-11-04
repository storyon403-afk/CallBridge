# Packaging and Uploading

Current: **0.0.3 / build 49**, tag **v0.0.3**, Apple Silicon/macOS 26+ and Windows 11 x64. Apple distribution signing/notarization and Windows publisher signing are deferred; retain those disclosures in downloads.

## Generate packages

Prepare tools using [source build](GETTING_STARTED.md#build-from-source), then run from root:

```sh
python3 scripts/prepare-sparkle.py
sh rust/scripts/build-app.sh
python3 scripts/prepare-release-runtime.py
python3 scripts/package-release.py
python3 scripts/check-release.py
```

`rust/build/releases/0.0.3/` contains macOS and Windows ZIPs, source archive, manifests, signed `appcast.xml`, `SHA256SUMS`. The final `github-release/` subfolder contains only the attachments to upload, without old `ui1`/`ui2` test packages. App ZIP includes Node, excluding personal recordings/voices/settings/speech models. Users install virtual audio/OBS separately. Source only: `python3 scripts/package-release.py --source-only`.

## Windows release payload

The 0.0.3 Windows release preserves every program/runtime/asset file from the maintainer-accepted `CallBridge-0.0.3-windows-x64-ui2.zip`. Only the archive root name, README, regression checklist and manifest are updated. `MANIFEST.json` records the accepted package SHA-256 and distinguishes maintainer-reported acceptance from automated archive checks. Keep the accepted test archive and pre-release backup locally; do not attach them to the release.

For future versions, build with `sh rust/scripts/build-windows-cross.sh` or the Windows build procedure, perform Windows acceptance on the resulting package, and then finalize its filename and documentation. Do not silently rebuild accepted executables. `python3 scripts/check-windows.py` verifies the final package; `python3 scripts/package-release.py` includes it and `WINDOWS-SHA256SUMS` in the combined checksum file.

## GitHub upload scope

Include source, build scripts, usage, licenses, `plugins/official/`, website assets, `SECURITY.md`, `THIRD_PARTY_NOTICES.md`. Keep `website/media/`, `assets/demos/`, `assets/diagrams/04.png` required by the site. Exclude `build/`, `target/`, `node_modules/`, `__pycache__/`, personal recordings/voices/settings. Generated `UPLOAD_FILES.txt` lists source contents.

## Publish the App

1. Commit/push prepared source.
2. Create a **draft** GitHub Release for **v0.0.3**, title **CallBridge 0.0.3**, targeting the pushed commit.
3. Use [release notes](release/NOTES.md), also copied as `RELEASE_NOTES.md` in the final attachment folder.
4. Attach **all 12 files** from `rust/build/releases/0.0.3/github-release/`: both platform ZIPs, source archive, `APP_MANIFEST.json`, `SOURCE_MANIFEST.json`, `UPLOAD_FILES.txt`, `SHA256SUMS`, `WINDOWS-SHA256SUMS`, `appcast.xml`, `GETTING_STARTED.md`, `SECURITY.md` and `RELEASE_NOTES.md`.
5. Review the attachments, retain signing/notarization disclosures, then publish the draft as the latest stable release. A Git push alone does not upload binaries or publish a GitHub Release.

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

Set Pages to **GitHub Actions**. Authorized pushes of source/assets to `main` deploy through `.github/workflows/pages.yml`. Preview via [website guide](website/README.md).

## Automatic update release contract

Sparkle is pinned by `release/sparkle.json`. Prepare it explicitly before the offline build. Development bundles set `CBEnableUpdates=false`; packaging enables it only in the staged release bundle. Diagnostic modes never initialize the updater. Release defaults enable checks every 86,400 seconds, automatic downloads, and installation on quit. No LaunchAgent is installed. Users can change the automatic-update preference from either menu.

The feed URL is `https://github.com/storyon403-afk/CallBridge/releases/latest/download/appcast.xml`. Every stable release must attach the generated `appcast.xml` **and** its corresponding App ZIP before it is designated GitHub's latest release. Use a draft release to upload all attachments first. Prereleases and plugin-only releases must not replace the latest stable App release. The feed references the immutable version tag, not the latest ZIP URL. Retain past App attachments. Future releases must increase the numeric `CFBundleVersion` as well as update the public version. Never reuse a published build number or replace a published archive.

Packaging uses Sparkle's `generate_appcast` and the macOS Keychain account `dev.callbridge.demo`. It checks that the account's public key matches `SUPublicEDKey` before signing. The private key is stored only in the maintainer's login Keychain; it is not exported into the repository, build output, or App. Back up that key securely before publishing the first updater-enabled release, and restore the same key when moving release machines. A missing/mismatched key stops packaging; do not generate a replacement key for an existing update channel. Source-only packaging needs no signing key.

Both feed and archive signatures are required; feed-validation failures never expire into unsigned fallback. `scripts/check-release.py` verifies those signatures, exact version/build/OS/download URL/length, packaged defaults, framework links, and payload hashes. The archive must not be changed after signing. SHA256SUMS includes the final signed feed. Publish only after these checks pass. The updater does not install drivers, models, or plugins. Gatekeeper, writable-location requirements, and Apple signing/notarization remain separate constraints. A system authorization prompt can prevent fully unattended installation in protected locations.

Versions through 0.0.2 have no updater and require one manual installation of 0.0.3 or later. Publishing files does not retrofit older clients. Local preparation does not publish a GitHub release.
