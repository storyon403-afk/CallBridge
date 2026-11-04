# Third-party components

CallBridge's noncommercial license applies to its original code only. It does not replace any license below. The release includes `Licenses/THIRD_PARTY_LICENSES.txt` and a dependency inventory generated from the actual locked Cargo packages.

| Component | Source / terms | Distribution |
| --- | --- | --- |
| Rust dependencies | Versions in the two `Cargo.lock` files; exact metadata and license texts in the generated inventory | Linked code in App/worker; copyright and license notices included |
| Three.js, three-vrm, KalidoKit | MIT; see `rust/avatar/package-lock.json` and bundled notices | Web renderer code; notices retained |
| Pocket TTS reference implementation | Kyutai MIT; `rust/pocket/POCKET-TTS-LICENSE` | Adapted inference code; license retained |
| Chinese default condition | Derived from the fixed public Pocket Chinese package; provenance in `rust/pocket/THIRD_PARTY.md` | Small compiled reference features, not a user's personal recording |
| Sparkle | [Sparkle project](https://github.com/sparkle-project/Sparkle), permissive license; version and archive digest in `release/sparkle.json` | Update framework and helpers bundled; full `SPARKLE-LICENSE` included |
| Node.js | Official locked ARM64 archive; Node and bundled component license text | App bundle includes the runtime and `NODE-LICENSE` |
| MediaPipe Holistic | Apache-2.0; optional engine downloads fixed upstream resources | Not bundled model weights; notices accompany the host |
| Original avatar | VRM1_Constraint_Twist_Sample, (c) 2022 pixiv Inc.; VRM Public License 1.0 and embedded settings | Optional App resource; original model also used by the website demo with its own notices |
| Pocket Chinese / English models, ONNX Runtime, WeText | Fixed sources and individual license files in `rust/pocket/assets/*package.json` and `rust/pocket/THIRD_PARTY.md` | Optional downloads; not bundled models. Upstream access terms still apply |
| DeepFilterNet3 | Official program under its own MIT/Apache notices | Optional local plugin; not included in the base release |
| OBS Studio / BlackHole | Separate GPL projects, independently installed | Neither application/driver is included in the CallBridge App archive |

The experimental CallBridge Link driver is a derivative of BlackHole under GPL-3.0, built separately by `rust/scripts/build-link.py`. It is not distributed in the default App archive and is not relicensed by the CallBridge license. Any separate driver distribution must include its corresponding source and original license.

Source and artifact preparation does not grant rights to redistribute users' voices, recordings or imported models. Private resources and settings are excluded from release inputs.
