# Third-party components

Koharu retains the upstream [MIT OR Apache-2.0 repository licenses](../../LICENSE-MIT), icon, translation prompt and Rawkuma navigation source.

## Bundled native runtimes

- [llama.cpp b12024](https://github.com/ggml-org/llama.cpp/tree/b12024), MIT. Official prebuilt XCFramework, archive SHA-256 `b7005ad25dab07d273794afc7ac24d55aeac1b52376301907c5fb4762e42545d`. License: `Resources/llama-LICENSE.txt`.
- [stable-diffusion-native v0.3.0](https://github.com/leehack/stable-diffusion-native/tree/v0.3.0), MIT; wraps [stable-diffusion.cpp at 0518b34374761cb82aeda5ad3c2f0686fdad2cec](https://github.com/leejet/stable-diffusion.cpp/tree/0518b34374761cb82aeda5ad3c2f0686fdad2cec), MIT. Prebuilt Apple XCFramework archive SHA-256 `3b83a0c21a00f6418890b679ea45b00c20d012da0a57fe989635b793e09f096a`. Both notices: `Resources/diffusion-LICENSE.txt`. No diffusion source tree is compiled by the app build.
- [Microsoft ONNX Runtime Swift package 1.24.2](https://github.com/microsoft/onnxruntime-swift-package-manager/tree/1.24.2), MIT. Its official binary package checksum is `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`. Runtime license: `Resources/onnxruntime-LICENSE.txt`.
- [Firebase Apple SDK 13.1.1](https://github.com/firebase/firebase-ios-sdk/tree/13.1.1), Apache-2.0; Analytics Core, Crashlytics, Messaging and Remote Config via Swift Package Manager. License: `Resources/firebase-LICENSE.txt`. Transitive packages retain their upstream notices and embedded privacy manifests.
- SwiftUI, WebKit, Vision, CoreML, Security and Metal are Apple platform frameworks.

## Optional downloadable models

Weights are not bundled or committed. `Resources/app-config.json` records exact commit-pinned URLs, byte counts and SHA-256 for every required file, including companion encoders and VAEs. These model cards and their license terms remain authoritative.

| Choice | Artifact / provenance | Publisher license |
|---|---|---|
| LaMa Manga | [mayocream/lama-manga-onnx](https://huggingface.co/mayocream/lama-manga-onnx/tree/b55497aadbfcb9740e1ed16f008268d71b4f3f79), ONNX export of dreMaz/AnimeMangaInpainting; replaces the former Dadm-n generic LaMa CoreML download | Apache-2.0 on the ONNX card |
| AOT GAN | [Liiesl/aot-inpainting-onnx](https://huggingface.co/Liiesl/aot-inpainting-onnx/tree/fde3692f488ff2ae9ffc411077666c20ccfcb969); all 168 learned tensors exactly match [mayocream/aot-inpainting at cffe2346ac2b5ebe1f2d61335d602d12cc144c6f](https://huggingface.co/mayocream/aot-inpainting/tree/cffe2346ac2b5ebe1f2d61335d602d12cc144c6f) after float32 conversion | Canonical weights MIT; third-party ONNX repository has no separate license declaration |
| Manga OCR | [mayocream/manga-ocr-onnx](https://huggingface.co/mayocream/manga-ocr-onnx/tree/24b12778d85800835e2ca409236de281b8ab7b9f), export of kha-white/manga-ocr-base | Apache-2.0 |
| Baberu OCR | [genshiai-daichi/baberu-ocr v1.2](https://huggingface.co/genshiai-daichi/baberu-ocr/tree/b9868433dbda3ed9ba1357d008599ff4ada873d5), publisher FP16 vision and INT8 prefill/step graphs | Apache-2.0 |
| Hayai OCR v2.1 | [JustANormalTinkerer/hayai-ocr-v2-onnx](https://huggingface.co/JustANormalTinkerer/hayai-ocr-v2-onnx/tree/685ae08ce48db204268854863722bcb292021e0d), publisher dynamic INT8 encoder/decoder | Apache-2.0 |
| PaddleOCR VL 1.6 | [PaddlePaddle/PaddleOCR-VL-1.6-GGUF](https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.6-GGUF/tree/511b09642bb324401f15f97cc23bc67e8f0a291d), official model and projector | Apache-2.0 |
| FLUX.2 Klein | [unsloth/FLUX.2-klein-4B-GGUF](https://huggingface.co/unsloth/FLUX.2-klein-4B-GGUF/tree/0084d1df98e2e2137fe776d55170bc4792ec1d66), with black-forest-labs/FLUX.2-small-decoder and unsloth/Qwen3-4B-GGUF | Apache-2.0 on the three cards |
| RORem mixed | [mayocream/RORem-mixed-GGUF](https://huggingface.co/mayocream/RORem-mixed-GGUF/tree/62c75b3e6f078a19e2698b0f677e8a4aa4c9ea56), with VAE, CLIP-L and CLIP-G from diffusers/stable-diffusion-xl-1.0-inpainting-0.1 | OpenRAIL++ |

OCR preprocessing/decoding follows the pinned publisher's `onnx_infer.py` (Baberu), `inference_onnx.py` (Hayai), and Manga OCR's ViT/TrOCR preprocessing and Japanese postprocessor. Paddle uses the pinned GGUF chat template's exact single-user rendering. Diffusion settings follow Koharu's model implementations: four Euler/FLUX2 steps for Klein and 30 Euler/discrete steps for RORem, including their companion weights, prompts and reference-image conditioning. iPad uses native-resolution 512-pixel context tiles and composites only the mask, a deliberate difference from whole-image generation.

Local text translation catalog: Qwen 3.5 and Gemma 4 GGUF conversions, Apache-2.0 according to their publisher cards and [Google's Gemma 4 license](https://ai.google.dev/gemma/apache_2). Exact repositories, revisions and weights are in `Resources/app-config.json`. Imported models have their own terms and hardware requirements.

Rawkuma is an external content source. This fork is not affiliated with the site or model publishers.

## Optional Anime Studio generation and upscaling models

Anima Turbo is derived from [CircleStone Labs Anima](https://huggingface.co/circlestone-labs/Anima). The upstream weights use [CircleStone Labs Non-Commercial License v1.2](https://huggingface.co/circlestone-labs/Anima/blob/f973fc41ec7545364ac9776c2440285f43ff2a30/LICENSE.md); a conversion repository's license does not replace those terms. The Qwen3-0.6B-Base text encoder and Qwen-Image VAE publish Apache-2.0 terms. `Resources/anima-config.json` pins these components and links the upstream Anima license. The app's MIT/Apache source-code licenses do not grant additional rights to model weights.

Settings → About links the repository's bundled MIT and Apache license texts, bundled native-runtime notices, and the optional models' source cards and license terms.

Real-ESRGAN by Xintao Wang and contributors, BSD-3-Clause: [source and license](https://github.com/xinntao/Real-ESRGAN), [model zoo](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/model_zoo.md). Weights are downloaded separately, never bundled. Copyright (c) 2021 Xintao Wang.

- Anime 6B: [AMD mirror](https://huggingface.co/amd/realesrgan-x4plus-anime-6b/tree/b14ff5f8ecb5a4b56ce4049a58d0bca1f8814690), `RealESRGAN_x4plus_anime_6B.pth`, SHA-256 `f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da`.
- General x4plus: [Annotators mirror](https://huggingface.co/lllyasviel/Annotators/tree/982e7edaec38759d914a963c48c4726685de7d96), `RealESRGAN_x4plus.pth`, SHA-256 `4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1`.
