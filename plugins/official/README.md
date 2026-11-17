# Official Plugins

Clone CallBridge first; download optional plugins in the App as needed. This directory stores catalog/sample source/instructions, not weights, private voices, or large packages.

## Usage

- Audio → audio plugins → official plugins.
- Mixing → file background → official plugins.
- Visuals → character/background list → official plugins.
- Menu-bar entry browses all; return to the feature to use.

Refresh → download → use. Equal/newer installed versions avoid duplicates. Downloads never play/open microphones/cameras. Local import remains. Engines retain their own pages/authorization, including user-owned English-model access.

## Samples

| Sample | Purpose | Dependency |
| --- | --- | --- |
| Light denoising | Pocket clear-mode parameters | Pocket during synthesis |
| Gentle ambience | 4-second low-level synthetic loop | None |
| Twilight background | Original 640×360 gradient | Visual engine |

Sources: [generator](../../scripts/package-official-plugins.py), directly importable [minimal parameters](examples/light-denoise). Samples follow the [noncommercial license](../../LICENSE), without real recordings/personal voices. Pending publication means refresh later; existing files may be imported directly.

## Character candidates

[Spider-Man and GG Bond](characters/README.md) are local VRM resource packages in the same catalog. They retain source and authorship declarations and remain unpublished. GG Bond is rebuilt locally from the user-approved visual reference with body/arm skinning; character publication rights remain unresolved. Prepare the locked Spider-Man source and run the character builder before packaging all five entries; the linked guide contains the exact commands and limitations.

## Package

From root:

```sh
python3 scripts/package-official-plugins.py
python3 scripts/check-official-plugins.py
```

Second command needs a built App. Outputs `.cbplugin`/`SHA256SUMS` in ignored `build/official-plugins/plugins-v1/`. Generation downloads no models, uses no devices, and reads no user plugin directory.

## Publish

See [upload scope](../../RELEASING.md#github-upload-scope). Maintainer steps, requiring authorization; scripts do not commit/push/publish:

1. Review/commit source, catalog, this directory.
2. Upload only the three reviewed sample `.cbplugin` files with their matching sample checksums and root `LICENSE` to this repository's **`plugins-v1` Release**, without a new App Release. Do not bulk-upload the build directory: the two character candidates remain excluded pending their separate review.
3. Once publicly downloadable:

   ```sh
   python3 scripts/package-official-plugins.py --verify-published
   ```

4. Download/compare the three sample packages; only full agreement marks those catalog entries downloadable. Character candidates remain unpublished. Review/push to `main`.
5. Users refresh/download on demand.

Never replace published-version contents. Increment version/Release tag and regenerate catalog. Archive root directly contains `manifest.json`. Only this repository's `plugins-*` Releases; no external scripts/arbitrary runtimes.

## Locations

```text
plugins/official/              Cloned metadata, examples, instructions
build/official-plugins/        Locally generated unpublished packages, outside Git
GitHub Releases / plugins-v1   Separately downloaded public packages
```

Install: `~/Library/Application Support/CallBridge/Plugins/Local/<id>/<version>/`; engines retain dedicated `Plugins/` directories. App bundles a small offline fallback, refreshing only explicitly, without stored tokens/auto-enabling. See [authoring tutorial](../../插件接入教程.md).

## Experimental frame avatars

macOS 0.0.4 adds CBFA v1 frame-avatar import and rendering. Experimental artwork and generated character packages are not shipped with the release; local frame-avatar build/preview helpers require separately supplied local resources. The built-in Cheng · Call Outfit remains available. Catalog character candidates remain unpublished.
