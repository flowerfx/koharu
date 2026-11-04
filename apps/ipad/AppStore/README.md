# App Store metadata

App: AI Anime Translator (`com.kurubyInteractive.aimanga`, Apple ID `6829665032`). Version: `1.0.0`.

`metadata/` contains 12 App Store localizations matching the app interface: en-US, en-GB, fr-FR, ar-SA, es-ES, pt-BR, de-DE, ja, ko, zh-Hans, zh-Hant, vi. The base `en` interface resource is covered by en-US. App Store regional choices map French to France, Spanish to Spain, Portuguese to Brazil and Arabic to ar-SA.

The copy describes importing static manga/anime images or image folders, OCR, translation/reading, image generation and credit/subscription requirements. It reflects the current full-safe release and does not advertise Rawkuma. Describe material functionality changes in metadata and App Review notes when releasing them.

Files follow fastlane deliver's metadata layout. The text files are the authoritative metadata. App display names remain unchanged; new locale subtitles are localized.

## CLI use

[fastlane deliver](https://docs.fastlane.tools/actions/deliver/) can upload this folder after installing fastlane and configuring an App Store Connect API key. Metadata-only upload from the repository root:

```sh
fastlane deliver \
  --app_identifier com.kurubyInteractive.aimanga \
  --app_version 1.0.0 \
  --platform ios \
  --metadata_path apps/ipad/AppStore/metadata \
  --api_key_path /absolute/protected/path/app-store-connect-api-key.json \
  --skip_binary_upload true \
  --skip_screenshots true \
  --skip_app_version_update true \
  --submit_for_review false
```

Use an existing, suitably scoped App Store Connect API key with Key ID, Issuer ID and private `.p8` key. Do not commit credentials. No API key is included or created here. The current update used the authorized Chrome session.

[asc](https://github.com/rorkai/App-Store-Connect-CLI) is another third-party CLI using Apple's official App Store Connect API. Its current metadata workflow supports validation and dry runs; check the installed version's help before applying a folder.

Store metadata languages are separate from UI and translation-target languages. Creating localizations does not change country availability or publish a release. No build upload, resubmission or production configuration switch is part of this metadata update.
