# Official plugins / 官方插件

Clone CallBridge first. Download optional plugins inside the app when you need them.

先克隆软件，用到插件时再在 App 内下载。这个目录只存清单、样例源码和说明，不存模型权重、私人音色或大型插件包。

## 使用

- 音频：**音频模拟 → 音频插件 → 官方插件**。
- 背景音：**混音设置 → 文件背景 → 官方插件**。
- 画面：**画面处理 → 人物／背景插件列表 → 官方插件**。
- 菜单栏 **官方插件** 可浏览全部样例；回对应功能入口选择使用。

点 **刷新列表 → 下载 → 使用**。已安装显示“已下载”，相同或更高版本不重复下载。下载不会自动播放、开麦或开摄像头；本地导入继续保留。

中文、英文与画面引擎继续使用各自页面现有的下载按钮；英文模型仍需用户自己的访问授权。

## 样例

| 样例 | 用途 | 依赖 |
| --- | --- | --- |
| 轻度降噪 | Pocket 清晰输出的参数包 | 合成时需要 Pocket |
| 柔和环境音 | 4 秒低电平合成环境音，可循环 | 无 |
| 暮色背景 | 640×360 原创渐变背景 | 画面引擎 |

样例源码在 [生成脚本](../../scripts/package-official-plugins.py)，可直接导入的最小参数包在 [examples/light-denoise](examples/light-denoise)。样例遵循项目 [非商业许可](../../LICENSE)。不包含真人录音或个人音色。

如果 App 显示 **待发布**，请稍后再刷新；已有包可以直接导入。

## 打包

在仓库根目录运行：

```sh
python3 scripts/package-official-plugins.py
python3 scripts/check-official-plugins.py
```

第二条需要先构建 App。生成的 `.cbplugin` 和 `SHA256SUMS` 位于 `build/official-plugins/plugins-v1/`，该目录不进入 Git。生成过程不下载模型、不使用设备、不读取用户插件目录。

## 发布

源码、插件附件及本地缓存的提交范围见 [GitHub 上传范围](../../RELEASING.md#github-上传范围)。

以下为维护者手动步骤，打包脚本不会提交、推送或发布：

1. 审阅并提交源码、此目录及清单。
2. 将三个 `.cbplugin`、`SHA256SUMS` 和根目录 `LICENSE` 上传到本仓库的 **`plugins-v1` Release**；不用创建新的 App Release。
3. 附件公开可下载后执行：

   ```sh
   python3 scripts/package-official-plugins.py --verify-published
   ```

4. 脚本逐个下载并比对实际字节，全部一致后才将 `catalog.json` 标为可下载。审阅并推送这份清单到 `main`。
5. 用户在 App 点击 **刷新列表**，随后按需下载。

不要替换已发布版本的内容；更新插件版本与 Release 标签，再生成新的清单。归档根目录必须直接包含 `manifest.json`。下载目录固定为本仓库的 `plugins-*` Release，不能在清单中塞入外部脚本或任意运行程序。

## 目录与安装位置

```text
plugins/official/              随源码克隆：下载清单、样例、说明
build/official-plugins/        本地生成：待发布插件包，不随 Git 克隆
GitHub Releases / plugins-v1   独立下载：公开插件包
```

安装目录仍为 `~/Library/Application Support/CallBridge/Plugins/Local/<id>/<version>/`。固定引擎继续使用 `Plugins/` 下的专属目录。App 只内置一份小型目录作为离线备用，显式刷新时才从官方仓库读取新目录；不保存令牌或自动启用插件。

更多类型与格式见 [插件接入教程](../../插件接入教程.md)。
