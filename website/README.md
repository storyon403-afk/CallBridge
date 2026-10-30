# 修改展示网站

在仓库根目录运行：

```sh
python3 website/build.py
python3 -m http.server 8765 --bind 127.0.0.1 --directory build/site
```

浏览器打开 `http://127.0.0.1:8765/`。不要直接双击 HTML，人物模型需要通过网页服务加载。

## 页面内容

- “动手试试”演示人物动作、背景切换、文字发送和插件导入，不会开启麦克风或摄像头。
- “使用体验”展示中英文操作面板。
- “微信实录”由使用者点击播放。
- “个人音色”介绍如何选择声音。

修改文字和展示位请看 `content.js`；页面交互在 `site.js`、`studio.js`，样式在 `style.css`。

## 更新素材

图片和视频放在 `media/`。原生面板图片使用 `ui-*.png` 和 `ui-en-*.png`。修改人物渲染源码后运行：

```sh
node website/scripts/build-demo.mjs
python3 website/build.py
```

首次依赖准备见根目录 [使用说明](../GETTING_STARTED.md#build-from-source)。提交时一起保留 `media/avatar-viewer.js`、`avatar-viewer.js.LEGAL.txt`、`cheng.vrm` 和 `demo-licenses.txt`，以及 `build.py` 引用的 `assets/demos/` 视频、封面和 `assets/diagrams/04.png`。

## 上传网站

仓库 Pages 设置选择 **GitHub Actions**。把官网源码和素材推送到 `main` 后，`.github/workflows/pages.yml` 会生成并上传页面。不要提交 `build/site/` 或 Python 缓存目录。
