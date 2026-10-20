# Pocket TTS 插件来源

- 模型、默认参考音色及示例音频：hustfyb/pocket-tts-zh-4l-onnx，固定 Hugging Face revision `e969e8bd2a1b2277e5d27ada3a859bdbe283322d`。上游 README 模型卡标记 Apache-2.0，随插件保存为 MODEL-README.md。当前仅本地集成，未公开重新分发；参考说话人来源及独立分发许可需在发布前另行确认。
- `assets/default-condition.f32`：由该 revision 的 kefu.wav 经原版 demo 修剪及 Pocket TTS 3.3.0 编码所得，保留完整 Float32，无降维、再量化或再训练。可用 `../scripts/pocket-reference.py` 重现。固定参考状态代替每次加载音色编码器，不影响该音色生成效果；0.7.0 的个人音色另按需加载原始 mimi_encode.onnx，保留原 Float32 speaker projection 与 BOS；不再量化编码器或降低特征维数。
- Rust 文本准备、分段及推理算法参考 Pocket TTS 3.3.0（Kyutai，MIT）及上述模型包；WeText 0.1.8 中文规范化图和字段顺序（Zhendong Peng，Apache-2.0）。相关上游声明保留在本目录和下载包中。
- ONNX Runtime 1.31.0：Microsoft，MIT；从官方 PyPI arm64 wheel 只提取原始动态库、LICENSE、ThirdPartyNotices.txt，SHA256 固定。不会执行 wheel 或安装 Python。
- 中文 TN 图：从官方 WeText 0.1.8 wheel 只提取中文 tagger/verbalizer 和 LICENSE，SHA256 固定；未用简化数字规则代替完整规范化。
- Rust 依赖版本见 Cargo.lock；主要为 ort（MIT/Apache-2.0）、rustfst（MIT/Apache-2.0）、sentencepiece-rust（Apache-2.0）、rand_mt（MIT/Apache-2.0）、hound（Apache-2.0）、zip（MIT）等。发布构建需携带全部静态依赖许可文本；本地构建不代表已完成发行签名或公证。

基础下载清单 `assets/package.json` 与可选参考编码器清单 `assets/encoder.json` 是编入 helper 的固定清单，不接受外部提供的任意下载地址、动态库、插件脚本或自定义算子。
