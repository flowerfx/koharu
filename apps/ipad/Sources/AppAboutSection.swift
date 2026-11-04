import SwiftUI

struct AppAboutSection: View {
    private var releaseName: String {
        let bundle = Bundle.main
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? L("AI Manga")
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(name) \(version) (\(build))"
    }
    var body: some View {
        Section(L("About")) {
            Text(releaseName).font(.headline).textSelection(.enabled)
            Text(L("Built using Koharu open-source components by Mayo Takanashi and contributors, licensed under MIT or Apache 2.0. The interface and processing workflows have been rebuilt natively for iOS and iPadOS."))
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink(L("Source code, models and licenses")) { AppAcknowledgementsScreen() }
            Text(L("Kuruby Server manages account sign-in, credits and membership status. With Backend API selected, it chooses the AI provider and model, processes translation and prompt-assistant requests, and provides content review."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("OCR detects text and recognizes the original dialogue on this device. Apple Vision is built in; Manga OCR, Baberu OCR, Hayai OCR and PaddleOCR are optional model downloads."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Inpainting removes source text and reconstructs its background on this device using LaMa, AOT GAN, FLUX.2 Klein or RORem. When disabled, the app uses white speech cards before rendering translated text."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Anime Studio generates images on this device with Anima and can upscale them with Real-ESRGAN. Downloaded model weights have their own licenses, separate from the app's source-code license."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Projects, manga pages and generated images are stored on this device. Translation providers receive extracted text and translation instructions. API keys are stored in Keychain."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L("Content and prompts that require review are sent through Kuruby Server to check compliance with the platform's content requirements."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AppAcknowledgementsScreen: View {
    var body: some View {
        List {
            Section(L("Source code")) {
                Text("Copyright © 2025–2026 Mayo Takanashi and Koharu contributors.")
                Link("Koharu", destination: URL(string: "https://github.com/koharu-rs/koharu")!)
                NavigationLink("MIT License") { BundledLicenseScreen(title: "MIT License", resource: "LICENSE-MIT", extension: nil) }
                NavigationLink("Apache License 2.0") { BundledLicenseScreen(title: "Apache License 2.0", resource: "LICENSE-APACHE", extension: nil) }
            }
            Section(L("Native runtimes")) {
                NavigationLink("llama.cpp · MIT") { BundledLicenseScreen(title: "llama.cpp · MIT", resource: "llama-LICENSE", extension: "txt") }
                NavigationLink("stable-diffusion-native / stable-diffusion.cpp · MIT") { BundledLicenseScreen(title: "stable-diffusion.cpp · MIT", resource: "diffusion-LICENSE", extension: "txt") }
                NavigationLink("ONNX Runtime · MIT") { BundledLicenseScreen(title: "ONNX Runtime · MIT", resource: "onnxruntime-LICENSE", extension: "txt") }
                NavigationLink("Firebase · Apache 2.0") { BundledLicenseScreen(title: "Firebase · Apache 2.0", resource: "firebase-LICENSE", extension: "txt") }
            }
            Section(L("Image generation and upscaling")) {
                Text(L("Anima Turbo is a derivative of Anima. The upstream Anima weights use the CircleStone Labs Non-Commercial License v1.2; the conversion repository's license does not replace the base model's terms."))
                if let anima = try? AnimeConfiguration.bundled() {
                    Link(anima.name, destination: anima.source)
                    Link("CircleStone Labs Non-Commercial License v1.2", destination: anima.license)
                }
                Link("Qwen3-0.6B-Base · Apache 2.0", destination: URL(string: "https://huggingface.co/Qwen/Qwen3-0.6B-Base")!)
                Link("Qwen Image VAE · Apache 2.0", destination: URL(string: "https://huggingface.co/Qwen/Qwen-Image")!)
                Link("Real-ESRGAN · BSD-3-Clause", destination: URL(string: "https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE")!)
            }
            Section(L("OCR models")) {
                Text(L("Apple Vision is an Apple platform framework. Optional OCR weights are downloaded separately under their publishers' terms."))
                ForEach(AppConfiguration.current.ocr.filter { !$0.builtIn }) { model in
                    Link(model.name + " · Apache 2.0", destination: model.source)
                }
                Link("Apple Vision", destination: URL(string: "https://developer.apple.com/documentation/vision")!)
            }
            Section(L("Inpainting models")) {
                ForEach(AppConfiguration.current.inpainting) { model in
                    Link(model.name, destination: model.source)
                }
                Text(L("LaMa Manga and FLUX.2 Klein publish Apache 2.0 terms. AOT GAN's canonical weights use MIT; its ONNX conversion repository does not declare a separate license. RORem combines Apache 2.0 components with an SDXL inpainting base under CreativeML Open RAIL++-M."))
                Link("AOT GAN · MIT", destination: URL(string: "https://huggingface.co/mayocream/aot-inpainting/tree/cffe2346ac2b5ebe1f2d61335d602d12cc144c6f")!)
                Link("RORem / SDXL · CreativeML Open RAIL++-M", destination: URL(string: "https://huggingface.co/diffusers/stable-diffusion-xl-1.0-inpainting-0.1")!)
            }
            Section(L("Local translation models")) {
                Text(L("Qwen 3.5 and Gemma 4 catalog models publish Apache 2.0 terms. Follow each model's source card for the downloaded revision and any companion-component terms. Imported models have their own licenses."))
                ForEach(AppConfiguration.current.gguf) { model in
                    if let url = modelCard(model.url) { Link(model.name, destination: url) }
                }
            }
            Section {
                Text(L("Source-code licenses do not grant additional rights to model weights. Each model publisher's license, copyright notices and usage conditions remain applicable."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L("Credits and licenses"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func modelCard(_ value: String) -> URL? {
        guard let url = URL(string: value), url.host == "huggingface.co" else { return nil }
        let path = url.pathComponents
        guard path.count > 5, path[3] == "resolve" else { return nil }
        return URL(string: "https://huggingface.co/\(path[1])/\(path[2])/blob/\(path[4])/README.md")
    }
}

private struct BundledLicenseScreen: View {
    let title: String
    let resource: String
    let `extension`: String?
    var body: some View {
        ScrollView {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: `extension`), let value = try? String(contentsOf: url, encoding: .utf8) else {
            return L("Could not load the bundled license.")
        }
        return value
    }
}
