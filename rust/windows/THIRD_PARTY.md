# Windows development dependencies

This port adds the following dependencies. Exact NuGet resolution and integrity hashes are in the project `packages.lock.json` files; Python direct pins are in `camera/requirements.txt`. The Windows build is a local development bundle, not a signed or approved redistributable release.

| Component | Purpose | Upstream |
| --- | --- | --- |
| .NET 10 / WPF / System.Speech | Desktop and Windows system speech | [dotnet](https://github.com/dotnet), MIT and third-party runtime notices |
| NAudio 2.2.1 | Explicit-endpoint WASAPI output and local file decoding | [NAudio](https://github.com/naudio/NAudio/tree/v2.2.1), MIT |
| Microsoft.Web.WebView2 SDK | Embedded existing renderer | [WebView2](https://learn.microsoft.com/en-us/microsoft-edge/webview2/), Microsoft SDK/runtime terms; Evergreen Runtime installed separately |
| Node.js | Existing loopback-only avatar resource/control server | [Node.js](https://nodejs.org/en/about/previous-releases); MIT plus bundled dependency notices |
| Python / NumPy | Separate RGBA transport process | [Python](https://www.python.org/), PSF; [NumPy](https://numpy.org/), BSD and bundled dependency notices |
| pyvirtualcam 0.15.0 | Windows OBS Virtual Camera backend | [source and license](https://github.com/letmaik/pyvirtualcam/tree/v0.15.0), GPL-2.0; includes upstream native components |
| LLVM-MinGW / libunwind | Cross-build linker and bundled unwind runtime | [LLVM-MinGW](https://github.com/mstorsjo/llvm-mingw), Apache-2.0 with LLVM exceptions and bundled notices |
| PyInstaller | Build-time freezing of the camera worker | [PyInstaller](https://pyinstaller.org/), GPL with its stated bootloader exception |

OBS, virtual audio drivers, Windows voices and WebView2 Runtime are not installed or licensed by CallBridge's build script. Existing avatar model/tracking licenses remain in the avatar payload.

Before external redistribution, preserve all notices and corresponding source obligations for the actual bundled components and review the camera worker's GPL dependency together with its Rust-library linkage and the repository's PolyForm license. Process separation alone is not asserted to resolve license compatibility. No new release, redistribution approval or third-party license grant is implied by this local migration. The helper source is included in development builds for inspection.

The portable cross-build uses CPython 3.13.9 embeddable, the pinned Windows wheels, and a small native process launcher instead of PyInstaller. The MSVC C++ runtime supplied by the NumPy wheel is also placed beside Python under its original DLL name for pyvirtualcam. All wheel metadata/license directories are preserved. Exact archive hashes are in `release/windows-runtime.json`. This bundle is for the requested private Windows evaluation; it does not resolve the external redistribution review described above.
