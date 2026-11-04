# Using Characters and Backgrounds

Open CallBridge → **Visual Processing**. Select character/background, download the engine if prompted, then open. App installation never automatically opens camera.

## Virtual character

Character replacement → virtual character → Cheng · Call Outfit. Inspect motion demo before explicitly opening camera/granting permission. Keep face/shoulders visible; hands follow only in frame. Plugins supply effects. TTS lip sync is absent.

## Replace backgrounds

Select static/flowing-light/window/custom. For background only, retain the person; categories can combine.

- Static: leave scene, capture, confirm.
- Live: camera surroundings, combinable with virtual character.
- Image/video: local import; system-decodable MP4/MOV/WebM ≤64 MiB/120 seconds/1920×1080, muted.

Occlusion/complex scenes can leave edge/fill artifacts. Move sensitive items out of view when privacy matters.

<a id="obs-local-call-testing"></a>

## Send to video calls

1. Install [OBS Studio](https://obsproject.com/download), approve virtual camera.
2. Quit OBS main application.
3. Open composition, select **OBS Virtual Camera**, explicitly start output.
4. Select the same camera in call client.
5. Stop when finished. Visual close/app hide/sleep also stops capture/output.

Keep preview visible. CallBridge Camera requires separate developer signing/setup; ordinary use follows OBS.

## Prepare assets from source

Requires Node.js 22+, npm, curl. From root:

```sh
sh rust/scripts/avatar-lab.sh prepare
sh rust/scripts/build-app.sh
```

Standalone browser: `cb avatar`, Chrome `http://127.0.0.1:5778`; OBS variant `cb avatar-obs`. Ctrl+C exits server. See [installation](../../GETTING_STARTED.md), [sources](THIRD_PARTY.txt).
