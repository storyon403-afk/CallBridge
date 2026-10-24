# 展示页面

本地打开：

```sh
python3 website/build.py
open build/site/index.html
```

展示位在 `website/content.js`。素材放进 `website/media/`，填写路径即可；没有素材就保留 `null`。

```js
{
  id: 'avatar',
  title: { zh: '虚拟形象', en: 'Avatar' },
  type: 'video',
  src: 'media/avatar.mp4',
  poster: 'media/avatar.jpg'
}
```

`type` 支持 `experience`（使用体验动画）、`pair`（操作 → 效果）、`image`、`video`。增加条目会自动增加标签。视频由访客主动播放。

GitHub Pages 使用 `.github/workflows/pages.yml`；仓库 Pages 来源选择 GitHub Actions 后，推送网页改动即可发布。当前只完成本地修改，未推送上线。

“使用体验”由 `experience.js` 驱动，使用 `media/ui-main.png`、`ui-video.png`、`ui-text.png` 三张中文原生窗口截图；英文页对应 `media/ui-en-main.png`、`ui-en-video.png`、`ui-en-text.png`，页面切换语言时同步切换素材。可替换素材而不改网页结构。原生 `--ui-smoke-capture` 会输出 `rust/build/app/ui-showcase-*.png`，需在本机检查截图后更新展示素材。

英文素材通过原生 `--ui-language-check en` 输出到 `rust/build/app/ui-en-*.png`：使用深色英文界面和英文演示草稿，不合成、不发送。检查截图后只复制 main、video、text 三张到 `website/media/`。
