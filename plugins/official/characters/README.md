# Character resource candidates

These are CallBridge-packaged character resources, not character-owner endorsements. Both catalog entries are **unpublished**. No download, installation, capture or virtual-device output starts automatically.

| Package | Source / attribution | Adaptation | Status |
| --- | --- | --- | --- |
| `org.callbridge.spider-man` | [Mr. P / Homecoming Tech Suit](https://sketchfab.com/3d-models/spider-man-2017-homecoming-tech-suit-6f58018044e147c08b8c2d7f552f46d1), retrieved from a pinned [public mirror](https://github.com/MartinDelophy/everyone-is-spiderman/tree/d4de847166a5cea04b0bfeed09dba056e816673f/public/models) | Original weighted body/finger rig; VRM 1 mapping; T-pose mesh and bind baking; portrait scale; embedded PNG textures limited to 1024 px | Local candidate. Embedded source metadata declares [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Character endorsement / publication clearance is not established. No facial morph targets added. |
| `org.callbridge.gg-bond` | User-approved [1905 character reference](https://image14.m1905.cn/uploadfile/2014/0515/20140515110708414563.jpg); locally authored geometry in `scripts/gg_bond_geometry.py` | Rounded face, brown irises, double-lobed red cap, raised snout, smile, gold chest emblem, gloves and boots; body/arm rig, T-pose baking and portrait placement | **Local reference reconstruction.** Replaces the rejected amaraha fan mesh; none of that mesh or its texture is reused. Character rights are not cleared for publication. |

**Likeness status: rejected by the user.** The current GG Bond package is a retained technical prototype, not an accepted visual deliverable. Passing import and deformation checks does not establish character fidelity.

GG Bond is a parameterized reconstruction from one approved image, not the animated series' production asset or an exact multiview reconstruction. The back and unshown details are approximations. Its face is rigid: no blink, mouth shapes or individual finger movement. Body/arm deformation is suitable for local evaluation; no measured live tracking, camera output or real-call compatibility is claimed. Spider-Man retains its original source geometry and skin weights.


## Reproduce locally

Use Python 3 with NumPy and Pillow, and the project's already prepared avatar dependencies. No executable source asset is run. All downloaded bytes are checked against [sources.json](sources.json).

From the repository root:

```sh
python3 scripts/build-character-plugins.py --fetch-spider-man
python3 scripts/package-official-plugins.py
python3 scripts/check-official-plugins.py
node rust/avatar/scripts/check-official-characters.mjs
```

Omit `--fetch-spider-man` when its locked source is cached. GG Bond is rebuilt entirely from local geometry parameters and needs no downloaded mesh or reference bitmap at build time. Missing or changed Spider-Man source bytes fail explicitly. Assets stay outside Git in the existing plugin build path:

```text
build/official-plugins/sources/           Locked downloaded resources
build/official-plugins/characters/        Generated self-contained VRM files
build/official-plugins/plugins-v1/        .cbplugin archives and SHA256SUMS
rust/build/official-character-check/     Renderer screenshots and checks
```

The host checks require an existing built App and Pocket worker. The renderer check uses an isolated headless browser, blocks external requests and capture, and substitutes the output bridge. It checks load, visible pixels, head framing, actual skinned-vertex deformation, and zero capture calls. It does not start the installed GUI or use personal browser profiles.

## Use and publication

Use the existing **Visuals → character list → local import** flow to import a generated `.cbplugin`. The visual engine `avatar-holistic-v1` / `1.0.0` must already be installed. This task does not install plugins in the user's profile.

The main catalog contains both entries with `published=false`, so online download remains pending. The packaging script keeps these character entries out of online publication verification while review is pending; existing sample verification still works. Source declarations, authorship, references and adaptation notes are embedded in each VRM and manifest. The repository's PolyForm license does not replace third-party asset terms. Publication requires a separate review and explicit authorization; it is not implied by producing a local package.
