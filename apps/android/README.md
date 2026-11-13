# AI Manga Translator for Android

Native Android app, version **1.0.1 (build 2)**: Kotlin + Jetpack Compose UI with **Material 3 Expressive** (`MaterialExpressiveTheme`, expressive motion, wavy progress, loading indicator, flexible top app bar). The palette is built around the pink of the iOS app icon, which is also the launcher icon (adaptive icon over `#FF47B4`). Settings → Appearance offers System / Light / Dark and optional Material You wallpaper colors (Android 12+, off by default). The processing core is Rust (`core/`), called through [UniFFI](https://mozilla.github.io/uniffi-rs/) Kotlin bindings.

## What it does

Bottom tabs: **Library**, **Rawkuma** (hidden in `full-safe` or without a configured site), **Anime Studio** and **Settings**; the reader and the import screen open full screen and Back returns to the tabs.

1. **Library** – **Import pages** opens an in-app picker in the app theme: device folders (MediaStore, photo permission; Android 14+ limited access supported), pages in natural file-name order, numbered multi-select. **Browse files** keeps the system picker for cloud drives and other apps. Long-press a chapter to delete it.
1. **Rawkuma** – WebView restricted to the `rawkuma.url` site from app-config.json, with the shared `packages/bridge/src/rawkuma-navigation.js` injected at document start and the same chapter query as iPad. A detected chapter shows **Translate chapter**: pages download from `cdn.rawkuma.com` (four at a time, Rust), the series page is read for title/alternative titles/genres/synopsis (sent as `series` reference data, like iPad), then the reader opens and translation starts. `half-safe` shows the external-content warning and blocks configured genres; `full-safe` removes the tab.
2. **Reader** – right-to-left pager, Original/Translated toggle, **Translate** runs the chapter pipeline with progress and cancel.
3. **Settings** – provider (only those enabled by app-config.json), API key (AES-GCM with an Android Keystore key), model list fetched from the provider, target language (the shared 43-entry catalog), extra instructions, dynamic color. Interface: English and Vietnamese.

## Anime Studio

Local anime image generation with the same Anima Turbo v1.1 Q8_0 catalog as iPad (`apps/ipad/Resources/anima-config.json`, read and validated by Rust `anime.rs`): three Hugging Face files (3.69 GB) downloaded by the Rust core with resume (`<file>.part`, HTTP Range), size check and SHA-256 before the final name. Generation uses the iPad sampling settings (Euler, sgm_uniform, cfg 1, VAE tiling 256, sizes 512×512 … 1024×1280, 5–20 steps) through `core/src/anima.c`, a C port of the iPad `koharu_anima_*` job, linked against the prebuilt **stable-diffusion-native v0.3.0** Android arm64 runtime (CPU only). Gradle task `sdRuntime<Variant>` downloads that archive once into `Vendor/` (git-ignored), checks its pinned SHA-256 and packages `libstable-diffusion.so`; x86_64 builds report generation unavailable. Images are stored in `files/anime/` with an `images.json` inventory and can be saved to `Pictures/AI Manga Translator`.

Admission follows iPad: `minimumDeviceMemoryBytes` (8 GB) — compared at 90% because Android reports RAM after the kernel reserve — and generation runs only in `none-safe`, since half/full-safe need the backend prompt review Android does not have yet. Not ported: RealESRGAN upscaler, prompt assistant, credits.

## Translation runs

A chapter translates only pages without a translation; **Retranslate** (button, reader menu, library long-press) translates every page again, and the reader menu can retranslate the current page only. With Backend API a retranslation reserves credits as a `rerun` (`cost_rerun_backend`). **Enhanced translation** always uses Backend API (`translateEnhanced`, priced 2 × (translate + surcharge)): the server translates the chapter, then reviews it with `apps/ipad/Resources/translation-review-system.txt`. A chapter saved in another target language is copied first, so its earlier translation is kept (iPad `startRun`).

## Reading and interface

Settings → Appearance: **App language** (System default and the 12 iPad interface languages, each named in its own language; Android 13+ stores it as the per-app locale, older versions apply it on activity creation; Arabic is right-to-left), **Reading mode** (horizontal right-to-left swipes or vertical scrolling), theme and dynamic color. Translation targets are named in the interface language. Locale files other than English and Vietnamese reuse the iPad `Localizable.strings` where the English text matches and are otherwise translated.

## Firebase and signing

`app/google-services.json` (project `kuruby-aimanga-production`) enables Analytics, Crashlytics and Remote Config (`data/CloudServices.kt`, port of iPad `CloudServices`): advertising consent denied, only `screen_view` names are logged, Crashlytics collects in release builds only. Remote Config shares `game_version` and `force_update_enabled` with iPad; the blocking update screen needs Android's own `google_play_url` (this app's Play listing) in the Firebase template. Push notifications are not ported.

Debug and release use the same application ID and the app key in `AndroidKeystore/` (git-ignored: PKCS12 `android.keystore`, password `android.keystore.pass` in `keystore.properties`, alias `android`). Without that folder, release falls back to the debug key.

## Remote configuration

Like the iPad app, the build reads `env/<environment>/<versionName>/configs/app-config.json` from the public S3 bucket: ListObjectsV2 on the exact prefix, then GetObject with `If-Match` only when the listed ETag or LastModified changed (Rust `config.rs`). The validated document and its validators are saved under `files/RemoteConfiguration/<environment>/<version>/active.json` (atomic rename); a failure keeps the last valid document, and the bundled `apps/ipad/Resources/app-config.json` is the offline seed. It is checked on launch and on every return to the foreground, deferred while a chapter is translating; Settings → Configuration shows the status and has a manual check.

`versionName` is part of that path, so it must match a published configuration. Both variants use `production` (`KOHARU_ENVIRONMENT` build field) because staging has no 1.0.1 configuration. Android acts on `provider[].enable` and `defaults.provider`; when the default is a provider Android does not implement (currently `backend`), the first enabled Android provider is used. No signature is checked, matching iPad builds without `KoharuConfigSigningKey`.

## Pipeline and ownership

| Step | Owner |
| --- | --- |
| Japanese OCR (on-device, bundled model) | Kotlin – ML Kit `text-recognition-japanese` |
| Reading order + joining lines/columns into one segment per bubble | Rust `regions.rs` (port of the iPad `PagePipeline.recognize` merge) |
| Batched chapter translation, provider requests, structured-output contract | Rust `translate.rs` (port of iPad `Translation.swift` / `HostedTranslation.swift`) |
| Speech-bubble detection (flood fill, erosion retry, interior rectangle) | Rust `bubble.rs` (port of iPad `BubbleLayout.swift`) |
| White-box cleanup, text fitting, PNG output | Kotlin `PageRenderer` (`StaticLayout`) |

The Rust core bundles the same prompt as desktop/iPad (`crates/koharu-translator/src/translation-system.txt`) and the same target catalog (`apps/ipad/Resources/languages.json`); there is no second prompt path. Only recognized text leaves the device, never page images.

Providers: OpenAI, Anthropic, Gemini, DeepSeek, xAI Grok, OpenRouter, DeepL, and LM Studio (any OpenAI-compatible server on the local network; cleartext HTTP is allowed for that case).

Not ported yet: Anime upscaler and prompt assistant, Backend API (Nakama sign-in, credits, enhanced translation, prompt moderation), local GGUF, AI inpainting (LaMa/FLUX), Qwen/MiniMax region settings, billing.

## Build

Requirements: JDK 17+, Android SDK (platform 37 is installed automatically by AGP), NDK `30.0.14904198`, Rust with `aarch64-linux-android` and `x86_64-linux-android` targets, and `cargo-ndk`.

```bash
cd apps/android
./gradlew assembleDebug     # app/build/outputs/apk/debug/app-debug.apk
./gradlew assembleRelease   # minified; signed with the debug key for local installs only
```

Gradle drives cargo for each variant (`cargoBuild<Variant>` → `jniLibs`, `uniffiBindings<Variant>` → generated Kotlin); nothing generated is committed. Rust unit tests: `cd core && cargo test`.

Toolchain: AGP 9.5.1, Gradle 9.9.1, Kotlin 2.4.21, Compose BOM 2026.09.00, material3 1.5.0-rc01 (needs compileSdk 37), minSdk 26, ABIs arm64-v8a and x86_64.

App ID: `com.kurubyInteractive.aimanga` for debug and release.
