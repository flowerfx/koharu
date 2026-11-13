import org.gradle.internal.os.OperatingSystem
import org.gradle.process.ExecOperations
import java.net.URI
import java.util.Properties
import java.security.MessageDigest
import javax.inject.Inject
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

val rustAbis = listOf("arm64-v8a", "x86_64")
val coreDir = rootProject.file("core")
/**
 * App signing key, kept out of git in `AndroidKeystore/`: a PKCS12 store with
 * one password (`android.keystore.pass` in keystore.properties) and alias `android`.
 */
val keystoreDir = rootProject.file("AndroidKeystore")
val keystorePassword = keystoreDir.resolve("keystore.properties").takeIf { it.exists() }?.let { file ->
    Properties().apply { file.inputStream().use { load(it) } }.getProperty("android.keystore.pass")
}

val cargoPath = File(System.getProperty("user.home"), ".cargo/bin/cargo").takeIf { it.exists() }?.path ?: "cargo"

android {
    namespace = "com.kurubyinteractive.aimanga"
    compileSdk = 37
    ndkVersion = "30.0.14904198"

    defaultConfig {
        applicationId = "com.kurubyInteractive.aimanga"
        minSdk = 26
        targetSdk = 36
        versionCode = 2
        // Also the remote configuration path: env/<environment>/<versionName>/configs/app-config.json.
        versionName = "1.0.1"
        // Staging has no 1.0.1 configuration, so every variant reads production.
        buildConfigField("String", "KOHARU_ENVIRONMENT", "\"production\"")
        ndk { abiFilters += rustAbis }
    }

    signingConfigs {
        if (keystorePassword != null) {
            create("app") {
                storeFile = keystoreDir.resolve("android.keystore")
                storeType = "pkcs12"
                storePassword = keystorePassword
                keyAlias = "android"
                keyPassword = keystorePassword
            }
        }
    }

    // Debug and release share the application ID and the app key, so either
    // build updates the other on a device and both match google-services.json.
    buildTypes {
        val app = signingConfigs.findByName("app")
        debug {
            app?.let { signingConfig = it }
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = app ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    // 1.5 carries the Material 3 Expressive theme, motion and components.
    implementation("androidx.compose.material3:material3:1.5.0-rc01")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("io.coil-kt.coil3:coil-compose:3.6.3")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("androidx.webkit:webkit:1.17.1")
    implementation(platform("com.google.firebase:firebase-bom:35.2.0"))
    implementation("com.google.firebase:firebase-analytics")
    implementation("com.google.firebase:firebase-crashlytics")
    implementation("com.google.firebase:firebase-config")
    // UniFFI's generated bindings load the Rust core through JNA.
    implementation("net.java.dev.jna:jna:5.19.1@aar")
}

// ---- Rust core (apps/android/core) ----

/** Runs cargo in the core crate; `{out}` in an argument is the task's output directory. */
abstract class CargoTask : DefaultTask() {
    @get:Inject abstract val execOperations: ExecOperations
    @get:InputFiles @get:PathSensitive(PathSensitivity.RELATIVE) abstract val sources: ConfigurableFileCollection
    @get:Internal abstract val crateDir: DirectoryProperty
    @get:Input abstract val cargo: Property<String>
    @get:Input abstract val ndkHome: Property<String>
    /** Extracted stable-diffusion-native runtime; links the Anima job on arm64. */
    @get:Internal abstract val sdNativeDir: Property<String>
    /** Each entry is one cargo invocation, run in order. */
    @get:Input abstract val invocations: ListProperty<List<String>>
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun run() {
        val out = outputDir.get().asFile.apply { deleteRecursively(); mkdirs() }
        for (arguments in invocations.get()) {
            execOperations.exec {
                workingDir = crateDir.get().asFile
                environment("ANDROID_NDK_HOME", ndkHome.get())
                sdNativeDir.orNull?.let { environment("SD_NATIVE_DIR", it) }
                commandLine(listOf(cargo.get()) + arguments.map { it.replace("{out}", out.path) })
            }
        }
    }
}

val hostLib = coreDir.resolve(
    "target/debug/" + if (OperatingSystem.current().isMacOsX) "libkoharu_core.dylib" else "libkoharu_core.so",
)

fun CargoTask.configureCore() {
    group = "rust"
    // The core also bundles the shared translation prompt and language catalog.
    sources.from(
        coreDir.resolve("src"), coreDir.resolve("Cargo.toml"), coreDir.resolve("Cargo.lock"),
        rootProject.file("../../crates/koharu-translator/src/translation-system.txt"),
        rootProject.file("../ipad/Resources/languages.json"),
    )
    sources.from(coreDir.resolve("build.rs"), rootProject.file("../ipad/Resources/anima-config.json"))
    crateDir.set(coreDir)
    cargo.set(cargoPath)
    ndkHome.set(androidComponents.sdkComponents.ndkDirectory.map { it.asFile.path })
}

// stable-diffusion-native, pinned to the release the iPad app uses (scripts/bootstrap.py).
val sdVersion = "v0.3.0"
val sdArchive = "stable-diffusion-native-runtime-android-arm64-$sdVersion.tar.gz"
val sdSha256 = "a505480ada6a5f8af1fb1195b60320c5b263d86e9e320e46b97dd5d1c00b7bb0"
val sdRuntimeDir = rootProject.file("Vendor/sd-android-$sdVersion")

/**
 * Downloads and verifies the prebuilt Android runtime once into `Vendor/`
 * (ignored by git), then provides `arm64-v8a/libstable-diffusion.so` as jniLibs.
 */
abstract class SdRuntimeTask : DefaultTask() {
    @get:Inject abstract val execOperations: ExecOperations
    @get:Input abstract val archiveUrl: Property<String>
    @get:Input abstract val sha256: Property<String>
    @get:Internal abstract val vendorDir: DirectoryProperty
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun run() {
        val vendor = vendorDir.get().asFile
        val library = vendor.resolve("lib/libstable-diffusion.so")
        if (!library.exists()) {
            val archive = vendor.parentFile.resolve(archiveUrl.get().substringAfterLast('/')).apply { parentFile.mkdirs() }
            URI(archiveUrl.get()).toURL().openStream().use { input -> archive.outputStream().use { input.copyTo(it) } }
            val digest = MessageDigest.getInstance("SHA-256").digest(archive.readBytes())
                .joinToString("") { "%02x".format(it) }
            check(digest == sha256.get()) { "${archive.name}: SHA-256 mismatch" }
            vendor.deleteRecursively(); vendor.mkdirs()
            execOperations.exec { commandLine("tar", "-xzf", archive.path, "-C", vendor.path) }
            archive.delete()
        }
        val out = outputDir.get().asFile.apply { deleteRecursively(); mkdirs() }
        library.copyTo(out.resolve("arm64-v8a/libstable-diffusion.so"))
    }
}

/**
 * Assets shared with the iPad app: the Rawkuma navigation script, and the
 * backend identity (server key + development CA). The identity files are
 * git-ignored secrets; a build without them has no Backend API.
 */
abstract class SharedAssetsTask : DefaultTask() {
    @get:InputFile @get:PathSensitive(PathSensitivity.NONE) abstract val navigationScript: RegularFileProperty
    @get:InputFiles @get:PathSensitive(PathSensitivity.NAME_ONLY) abstract val backendIdentity: ConfigurableFileCollection
    @get:OutputDirectory abstract val outputDir: DirectoryProperty

    @TaskAction
    fun run() {
        val out = outputDir.get().asFile.apply { deleteRecursively(); mkdirs() }
        navigationScript.get().asFile.copyTo(out.resolve("rawkuma-navigation.js"))
        val files = backendIdentity.files.filter { it.exists() }
        if (files.size == 2) files.forEach { it.copyTo(out.resolve(it.name)) }
    }
}

androidComponents {
    onVariants { variant ->
        val assets = tasks.register<SharedAssetsTask>("sharedAssets${variant.name.replaceFirstChar { it.uppercase() }}") {
            navigationScript.set(rootProject.file("../../packages/bridge/src/rawkuma-navigation.js"))
            backendIdentity.from(rootProject.file("../ipad/Resources/nakama-connection.json"), rootProject.file("../ipad/Resources/nakama-connection.cer"))
        }
        variant.sources.assets?.addGeneratedSourceDirectory(assets, SharedAssetsTask::outputDir)
        val name = variant.name.replaceFirstChar { it.uppercase() }
        val release = variant.buildType == "release"
        val runtime = tasks.register<SdRuntimeTask>("sdRuntime$name") {
            archiveUrl.set("https://github.com/leehack/stable-diffusion-native/releases/download/$sdVersion/$sdArchive")
            sha256.set(sdSha256)
            vendorDir.set(sdRuntimeDir)
        }
        variant.sources.jniLibs?.addGeneratedSourceDirectory(runtime, SdRuntimeTask::outputDir)
        val libraries = tasks.register<CargoTask>("cargoBuild$name") {
            configureCore()
            dependsOn(runtime)
            sdNativeDir.set(sdRuntimeDir.path)
            invocations.set(listOf(buildList {
                addAll(listOf("ndk", "--platform", "26"))
                rustAbis.forEach { addAll(listOf("-t", it)) }
                addAll(listOf("-o", "{out}", "build", "--lib"))
                if (release) add("--release")
            }))
        }
        variant.sources.jniLibs?.addGeneratedSourceDirectory(libraries, CargoTask::outputDir)

        // Library mode reads the UniFFI metadata from a host build of the same crate.
        val bindings = tasks.register<CargoTask>("uniffiBindings$name") {
            configureCore()
            invocations.set(listOf(
                listOf("build", "--lib"),
                listOf(
                    "run", "--features", "bindgen", "--bin", "uniffi-bindgen", "--", "generate", "--no-format",
                    "--library", hostLib.path, "--language", "kotlin", "--out-dir", "{out}",
                ),
            ))
        }
        variant.sources.kotlin?.addGeneratedSourceDirectory(bindings, CargoTask::outputDir)
    }
}
