// The Anima job shim links the pinned stable-diffusion-native Android runtime.
// It exists for Android arm64 only; other targets (host builds that generate
// the bindings, x86_64 emulators) get `anima_available() == false`.

fn main() {
    println!("cargo::rustc-check-cfg=cfg(anima_native)");
    println!("cargo::rerun-if-env-changed=SD_NATIVE_DIR");
    println!("cargo::rerun-if-changed=src/anima.c");
    let target = std::env::var("TARGET").unwrap_or_default();
    let Ok(dir) = std::env::var("SD_NATIVE_DIR") else { return };
    if target != "aarch64-linux-android" {
        return;
    }
    cc::Build::new()
        .file("src/anima.c")
        .include(format!("{dir}/include"))
        .flag("-std=c11")
        .compile("koharu_anima");
    println!("cargo::rustc-link-search=native={dir}/lib");
    println!("cargo::rustc-link-lib=dylib=stable-diffusion");
    println!("cargo::rustc-link-lib=dylib=log");
    println!("cargo::rustc-cfg=anima_native");
}
