# Pocket TTS Plugin Sources

- Model/default reference/sample: hustfyb/pocket-tts-zh-4l-onnx, Hugging Face revision `e969e8bd2a1b2277e5d27ada3a859bdbe283322d`. Upstream model card declares Apache-2.0 and is retained as MODEL-README.md. Download on demand; source terms govern model/voice use.
- `assets/default-condition.f32`: original-demo trimming and Pocket TTS 3.3.0 encoding of that revision's kefu.wav, complete Float32 without dimension reduction/requantization/training. Reproduce with `../scripts/pocket-reference.py`. Fixed state avoids repeatedly loading the encoder without altering this voice's output. Since 0.7.0 personal voices separately load original mimi_encode.onnx on demand, preserving Float32 speaker projection/BOS, without encoder quantization/feature reduction.
- Rust text preparation/segmentation/inference refer to Pocket TTS 3.3.0 (Kyutai, MIT), the model package, and WeText 0.1.8 Chinese normalization graphs/field order (Zhendong Peng, Apache-2.0). Retain upstream notices here/in downloads.
- ONNX Runtime 1.31.0: Microsoft/MIT. Extract only original dylib/LICENSE/ThirdPartyNotices.txt from official PyPI arm64 wheel with pinned SHA256. Never execute wheel/install Python.
- Chinese TN: extract only tagger/verbalizer/LICENSE from official WeText 0.1.8 wheel, pinned SHA256; no simplified-number-rule replacement.
- Cargo.lock pins Rust dependencies, including ort (MIT/Apache-2.0), rustfst (MIT/Apache-2.0), sentencepiece-rust (Apache-2.0), rand_mt (MIT/Apache-2.0), hound (Apache-2.0), zip (MIT). Distribution must include all static dependency licenses. App lacks Apple distribution signing/notarization.

`assets/package.json` and optional `assets/encoder.json` compile into the helper as fixed manifests. No externally supplied arbitrary URLs/libraries/plugin scripts/custom operators.
