# Editing the Product Website

From root:

```sh
python3 website/build.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory build/site
```

Open `http://127.0.0.1:8765/`; do not double-click HTML because models need HTTP.

## Content

- Hands-on demo: character motion/background/text/mock import, no camera/microphone.
- Usage experience: Chinese/English native panels.
- WeChat recordings: explicitly played by users.
- Personal voices: voice-selection introduction.

Edit copy/placements in `content.js`, behavior in `site.js`/`studio.js`, styling in `style.css`.

## Assets

Use `media/`; native panels are `ui-*.png`/`ui-en-*.png`. After renderer source edits:

```sh
node website/scripts/build-demo.mjs
python3 website/build.py
```

See [initial dependencies](../GETTING_STARTED.md#build-from-source). Retain `media/avatar-viewer.js`, `avatar-viewer.js.LEGAL.txt`, `cheng.vrm`, `demo-licenses.txt`, and build.py's referenced `assets/demos/` videos/posters and `assets/diagrams/04.png`.

## Upload

Pages uses **GitHub Actions**. Authorized pushes to `main` build/deploy through `.github/workflows/pages.yml`. Do not commit `build/site/` or Python caches.
