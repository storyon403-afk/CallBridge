# 打包和上传

当前版本：**0.0.2 / build 48**，发布标签使用 **v0.0.2**。App 面向 Apple Silicon Mac、macOS 26 及以上。苹果发布签名和公证暂不办理，下载说明中应保留这一点。

## 生成安装包

先按 [使用说明](GETTING_STARTED.md#build-from-source) 准备构建工具，在仓库根目录运行：

```sh
sh rust/scripts/build-app.sh
python3 scripts/prepare-release-runtime.py
python3 scripts/package-release.py
python3 scripts/check-release.py
```

`rust/build/releases/0.0.2/` 会生成 App ZIP、源码压缩包、文件清单和 `SHA256SUMS`。App ZIP 已带 Node 运行环境，不带个人录音、音色、设备设置或语音模型。虚拟音频设备和 OBS 由使用者另行安装。

只需要源码包时运行 `python3 scripts/package-release.py --source-only`。

## GitHub 上传范围

把程序源码、构建脚本、使用说明、许可证、`plugins/official/` 和官网素材一起提交。`SECURITY.md`、`THIRD_PARTY_NOTICES.md` 也是公开文件。不要漏掉 `website/media/`、`assets/demos/`、`assets/diagrams/04.png`，网页需要它们。

不要提交 `build/`、`target/`、`node_modules/`、`__pycache__/`、个人录音、个人音色或设置。打包脚本会在发布目录生成 `UPLOAD_FILES.txt`，列出源码包包含的文件，方便对照。

## 发布 App

1. 提交并推送准备好的源码。
2. 在 GitHub Releases 新建 **v0.0.2**，标题写 **CallBridge 0.0.2**。
3. 使用 [更新说明](release/NOTES.md) 作为正文。
4. 上传发布目录中的 App ZIP、源码压缩包、`APP_MANIFEST.json`、`SOURCE_MANIFEST.json`、`SHA256SUMS` 和 `GETTING_STARTED.md`。
5. 保留“尚未经过苹果签名和公证”的说明，用户第一次打开时可能遇到系统提示。

这些脚本只生成文件，不会自动提交、推送或发布。

## 发布官方插件

```sh
python3 scripts/package-official-plugins.py
```

把 `build/official-plugins/plugins-v1/` 里的三个 `.cbplugin`、`SHA256SUMS` 和 `LICENSE` 上传到单独的 **plugins-v1** Release。不要把插件压缩包加入源码仓库。

附件可以下载以后，再运行：

```sh
python3 scripts/package-official-plugins.py --verify-published
```

它会核对下载内容，并更新 `plugins/official/catalog.json` 的下载状态。提交并推送更新后的清单。用户在 App 点“刷新列表”就能看到可下载的插件。详细说明见[官方插件](plugins/official/README.md)。

## 更新官网

Pages 设置选择 **GitHub Actions**。提交官网源码及素材后，推送到 `main` 会按 `.github/workflows/pages.yml` 更新网站。想先查看页面，按 [website/README.md](website/README.md) 操作。
