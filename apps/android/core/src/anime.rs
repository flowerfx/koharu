// Anime Studio: the Anima model catalog (shared apps/ipad/Resources/anima-config.json),
// verified model downloads and local image generation through the
// stable-diffusion-native runtime (see anima.c).

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use reqwest::Client;
use serde::Deserialize;
use sha2::{Digest, Sha256};

const CONFIG: &str = include_str!("../../../ipad/Resources/anima-config.json");

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AnimeError {
    #[error("invalid Anima model configuration")]
    InvalidConfiguration,
    #[error("image generation is not available on this device")]
    Unavailable,
    #[error("invalid image generation settings")]
    InvalidSettings,
    #[error("could not download {file}")]
    Download { file: String },
    #[error("{file} failed verification")]
    Checksum { file: String },
    #[error("stopped")]
    Cancelled,
    #[error("{detail}")]
    Native { detail: String },
    #[error("storage error: {detail}")]
    Storage { detail: String },
}

#[derive(Debug, Clone, Deserialize, uniffi::Record)]
pub struct AnimaFile {
    pub path: String,
    pub url: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AnimaComponent {
    /// `diffusion`, `textEncoder` or `vae`.
    pub role: String,
    pub file: AnimaFile,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AnimaConfig {
    pub id: String,
    pub name: String,
    pub minimum_device_memory_bytes: u64,
    pub source: String,
    pub license: String,
    pub components: Vec<AnimaComponent>,
    pub width: u32,
    pub height: u32,
    pub steps: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawComponent {
    role: String,
    file: AnimaFile,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawGeneration {
    width: u32,
    height: u32,
    steps: u32,
    cfg: f32,
    sampler: String,
    scheduler: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawConfig {
    id: String,
    name: String,
    minimum_device_memory_bytes: u64,
    source: String,
    license: String,
    components: Vec<RawComponent>,
    generation: RawGeneration,
}

/// Image sizes the native job accepts (same list as iPad `AnimeImageSize`).
pub const SIZES: [(u32, u32); 5] = [(512, 512), (768, 1024), (720, 1280), (1024, 1024), (1024, 1280)];

fn huggingface(url: &str) -> bool {
    url::Url::parse(url).is_ok_and(|u| {
        u.scheme() == "https" && u.host_str() == Some("huggingface.co") && u.username().is_empty()
            && u.password().is_none() && u.query().is_none() && u.fragment().is_none()
    })
}

/// The bundled Anima catalog, validated like the iPad `AnimeConfiguration.decode`.
#[uniffi::export]
pub fn anima_config() -> Result<AnimaConfig, AnimeError> {
    let raw: RawConfig = serde_json::from_str(CONFIG).map_err(|_| AnimeError::InvalidConfiguration)?;
    let g = &raw.generation;
    let roles: Vec<&str> = raw.components.iter().map(|c| c.role.as_str()).collect();
    let valid = raw.id == "anima-turbo-v1-1-q8-0"
        && !raw.name.is_empty()
        && raw.minimum_device_memory_bytes == 8_000_000_000
        && g.cfg == 1.0 && g.sampler == "euler" && g.scheduler == "sgm_uniform"
        && SIZES.contains(&(g.width, g.height)) && (5..=20).contains(&g.steps)
        && roles.len() == 3 && ["diffusion", "textEncoder", "vae"].iter().all(|r| roles.contains(r))
        && huggingface(&raw.source) && huggingface(&raw.license)
        && raw.components.iter().all(|c| {
            let f = &c.file;
            huggingface(&f.url) && f.bytes > 0 && f.sha256.len() == 64
                && f.sha256.bytes().all(|b| b.is_ascii_hexdigit())
                && !f.path.is_empty() && !f.path.contains('/') && !f.path.contains("..")
        });
    if !valid {
        return Err(AnimeError::InvalidConfiguration);
    }
    Ok(AnimaConfig {
        id: raw.id,
        name: raw.name,
        minimum_device_memory_bytes: raw.minimum_device_memory_bytes,
        source: raw.source,
        license: raw.license,
        components: raw.components.into_iter().map(|c| AnimaComponent { role: c.role, file: c.file }).collect(),
        width: g.width,
        height: g.height,
        steps: g.steps,
    })
}

/// Downloaded and verified files are kept under their final name only.
#[uniffi::export]
pub fn anima_file_ready(file: AnimaFile, directory: String) -> bool {
    std::fs::metadata(Path::new(&directory).join(&file.path)).is_ok_and(|m| m.len() == file.bytes)
}

#[uniffi::export(callback_interface)]
pub trait ModelDownloadProgress: Send + Sync {
    fn on_bytes(&self, done: u64, total: u64);
    /// Polled between chunks; returning true stops the download (the partial file is kept to resume).
    fn is_cancelled(&self) -> bool;
}

fn client() -> &'static Client {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        Client::builder()
            .connect_timeout(Duration::from_secs(20))
            .read_timeout(Duration::from_secs(60))
            .user_agent("KoharuPad/1.0")
            .build()
            .expect("HTTP client configuration is valid")
    })
}

fn storage(error: std::io::Error) -> AnimeError {
    AnimeError::Storage { detail: error.to_string() }
}

/// Downloads one model file into `directory`, resuming `<path>.part`, then
/// checks its size and SHA-256 before giving it its final name.
#[uniffi::export(async_runtime = "tokio")]
pub async fn download_anima_file(
    file: AnimaFile,
    directory: String,
    progress: Box<dyn ModelDownloadProgress>,
) -> Result<(), AnimeError> {
    if !huggingface(&file.url) {
        return Err(AnimeError::InvalidConfiguration);
    }
    let dir = PathBuf::from(&directory);
    std::fs::create_dir_all(&dir).map_err(storage)?;
    let target = dir.join(&file.path);
    if std::fs::metadata(&target).is_ok_and(|m| m.len() == file.bytes) {
        return Ok(());
    }
    let partial = dir.join(format!("{}.part", file.path));
    let progress: Arc<dyn ModelDownloadProgress> = Arc::from(progress);
    let failed = || AnimeError::Download { file: file.path.clone() };

    let mut done = std::fs::metadata(&partial).map(|m| m.len()).unwrap_or(0);
    if done > file.bytes {
        std::fs::remove_file(&partial).map_err(storage)?;
        done = 0;
    }
    if done < file.bytes {
        let mut request = client().get(&file.url);
        if done > 0 {
            request = request.header("Range", format!("bytes={done}-"));
        }
        let mut response = request.send().await.map_err(|_| failed())?;
        let status = response.status();
        if done > 0 && status != reqwest::StatusCode::PARTIAL_CONTENT {
            // The server ignored the range: start over.
            done = 0;
        }
        if !status.is_success() {
            return Err(failed());
        }
        let mut out = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .append(done > 0)
            .truncate(done == 0)
            .open(&partial)
            .map_err(storage)?;
        progress.on_bytes(done, file.bytes);
        while let Some(chunk) = response.chunk().await.map_err(|_| failed())? {
            if progress.is_cancelled() {
                return Err(AnimeError::Cancelled);
            }
            done += chunk.len() as u64;
            if done > file.bytes {
                drop(out);
                let _ = std::fs::remove_file(&partial);
                return Err(failed());
            }
            out.write_all(&chunk).map_err(storage)?;
            progress.on_bytes(done, file.bytes);
        }
        out.flush().map_err(storage)?;
        if done != file.bytes {
            return Err(failed());
        }
    }

    // Hash the whole file, resumed prefix included.
    let expected = file.sha256.to_ascii_lowercase();
    let check = partial.clone();
    let digest = tokio_blocking(move || -> std::io::Result<String> {
        let mut reader = std::io::BufReader::with_capacity(1 << 20, std::fs::File::open(check)?);
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; 1 << 20];
        loop {
            let read = reader.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
        Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
    })
    .await
    .map_err(storage)?;
    if digest != expected {
        let _ = std::fs::remove_file(&partial);
        return Err(AnimeError::Checksum { file: file.path.clone() });
    }
    std::fs::rename(&partial, &target).map_err(storage)?;
    Ok(())
}

/// Runs blocking work off the async executor thread.
async fn tokio_blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    let (sender, receiver) = futures::channel::oneshot::channel();
    std::thread::spawn(move || {
        let _ = sender.send(work());
    });
    receiver.await.expect("hashing thread finished")
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AnimaProgress {
    /// 0 idle, 1 loading the model, 2 generating, 3 done.
    pub phase: i32,
    pub step: i32,
    pub steps: i32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct AnimaPaths {
    pub diffusion: String,
    pub text_encoder: String,
    pub vae: String,
}

/// Optional ×4 upscalers after Anima (iPad `AnimeUpscaler`): only RGB RRDB
/// models the pinned runtime supports, each with an immutable download.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AnimeUpscaler {
    /// `anime4` or `general4`.
    pub id: String,
    pub name: String,
    pub scale: u32,
    pub file: AnimaFile,
}

#[uniffi::export]
pub fn anime_upscalers() -> Vec<AnimeUpscaler> {
    vec![
        AnimeUpscaler {
            id: "anime4".into(),
            name: "RealESRGAN anime 6B · 4×".into(),
            scale: 4,
            file: AnimaFile {
                path: "RealESRGAN_x4plus_anime_6B.pth".into(),
                url: "https://huggingface.co/amd/realesrgan-x4plus-anime-6b/resolve/b14ff5f8ecb5a4b56ce4049a58d0bca1f8814690/RealESRGAN_x4plus_anime_6B.pth".into(),
                bytes: 17_938_799,
                sha256: "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da".into(),
            },
        },
        AnimeUpscaler {
            id: "general4".into(),
            name: "RealESRGAN x4plus · 4×".into(),
            scale: 4,
            file: AnimaFile {
                path: "RealESRGAN_x4plus.pth".into(),
                url: "https://huggingface.co/lllyasviel/Annotators/resolve/982e7edaec38759d914a963c48c4726685de7d96/RealESRGAN_x4plus.pth".into(),
                bytes: 67_040_989,
                sha256: "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1".into(),
            },
        },
    ]
}

#[uniffi::export]
pub fn anima_available() -> bool {
    cfg!(anima_native)
}

#[cfg(anima_native)]
mod native {
    use std::ffi::{c_char, c_int, c_void};
    unsafe extern "C" {
        pub fn koharu_anima_job_new() -> *mut c_void;
        pub fn koharu_anima_job_free(job: *mut c_void);
        pub fn koharu_anima_job_cancel(job: *mut c_void);
        pub fn koharu_anima_job_progress(job: *mut c_void, step: *mut c_int, steps: *mut c_int) -> c_int;
        pub fn koharu_anima_generate(
            job: *mut c_void, diffusion: *const c_char, text: *const c_char, vae: *const c_char,
            prompt: *const c_char, width: c_int, height: c_int, steps: c_int, seed: i64, threads: c_int,
            output: *mut u8, error: *mut c_char, capacity: usize,
        ) -> c_int;
        pub fn koharu_anima_upscale(
            job: *mut c_void, model: *const c_char, rgb: *const u8, width: c_int, height: c_int, scale: c_int,
            threads: c_int, output: *mut u8, output_capacity: usize, error: *mut c_char, capacity: usize,
        ) -> c_int;
    }
}

/// One generation: create, run `generate` on a background thread, and call
/// `cancel` / `progress` from any other thread.
#[derive(uniffi::Object)]
pub struct AnimaJob {
    #[cfg_attr(not(anima_native), allow(dead_code))]
    pointer: *mut std::ffi::c_void,
}

// The native job synchronizes cancellation with context teardown internally.
unsafe impl Send for AnimaJob {}
unsafe impl Sync for AnimaJob {}

#[uniffi::export]
impl AnimaJob {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, AnimeError> {
        #[cfg(anima_native)]
        {
            let pointer = unsafe { native::koharu_anima_job_new() };
            if pointer.is_null() {
                return Err(AnimeError::Unavailable);
            }
            Ok(Arc::new(Self { pointer }))
        }
        #[cfg(not(anima_native))]
        Err(AnimeError::Unavailable)
    }

    pub fn cancel(&self) {
        #[cfg(anima_native)]
        unsafe { native::koharu_anima_job_cancel(self.pointer) }
    }

    pub fn progress(&self) -> AnimaProgress {
        #[cfg(anima_native)]
        {
            let (mut step, mut steps) = (0, 0);
            let phase = unsafe { native::koharu_anima_job_progress(self.pointer, &mut step, &mut steps) };
            AnimaProgress { phase, step, steps }
        }
        #[cfg(not(anima_native))]
        AnimaProgress { phase: 0, step: 0, steps: 0 }
    }

    /// Blocking. Upscales `width × height × 3` RGB with a RealESRGAN model;
    /// returns `(width·scale) × (height·scale) × 3` RGB bytes.
    pub fn upscale(&self, model: String, rgb: Vec<u8>, width: u32, height: u32, scale: u32, threads: u32) -> Result<Vec<u8>, AnimeError> {
        if scale != 4 || width == 0 || height == 0 || width > 1024 || height > 1280 || rgb.len() != (width * height * 3) as usize {
            return Err(AnimeError::InvalidSettings);
        }
        #[cfg(anima_native)]
        {
            let model = std::ffi::CString::new(model).map_err(|_| AnimeError::InvalidSettings)?;
            let mut output = vec![0u8; (width * scale * height * scale * 3) as usize];
            let mut error = vec![0 as std::ffi::c_char; 8192];
            let ok = unsafe {
                native::koharu_anima_upscale(
                    self.pointer, model.as_ptr(), rgb.as_ptr(), width as i32, height as i32, scale as i32, threads as i32,
                    output.as_mut_ptr(), output.len(), error.as_mut_ptr(), error.len(),
                )
            };
            if ok != 0 {
                return Ok(output);
            }
            let detail = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }.to_string_lossy().into_owned();
            if detail.is_empty() { Err(AnimeError::Cancelled) } else { Err(AnimeError::Native { detail }) }
        }
        #[cfg(not(anima_native))]
        {
            let _ = (model, threads);
            Err(AnimeError::Unavailable)
        }
    }

    /// Blocking. Returns `width × height × 3` RGB bytes.
    #[allow(clippy::too_many_arguments)]
    pub fn generate(
        &self,
        paths: AnimaPaths,
        prompt: String,
        width: u32,
        height: u32,
        steps: u32,
        seed: i64,
        threads: u32,
    ) -> Result<Vec<u8>, AnimeError> {
        let prompt = prompt.trim().to_owned();
        if prompt.is_empty() || prompt.chars().count() > 4096 || !SIZES.contains(&(width, height)) || !(5..=20).contains(&steps) {
            return Err(AnimeError::InvalidSettings);
        }
        #[cfg(anima_native)]
        {
            use std::ffi::CString;
            let text = |s: String| CString::new(s).map_err(|_| AnimeError::InvalidSettings);
            let (diffusion, encoder, vae, prompt) =
                (text(paths.diffusion)?, text(paths.text_encoder)?, text(paths.vae)?, text(prompt)?);
            let mut output = vec![0u8; (width * height * 3) as usize];
            let mut error = vec![0 as std::ffi::c_char; 8192];
            let ok = unsafe {
                native::koharu_anima_generate(
                    self.pointer, diffusion.as_ptr(), encoder.as_ptr(), vae.as_ptr(), prompt.as_ptr(),
                    width as i32, height as i32, steps as i32, seed, threads as i32,
                    output.as_mut_ptr(), error.as_mut_ptr(), error.len(),
                )
            };
            if ok != 0 {
                return Ok(output);
            }
            let detail = unsafe { std::ffi::CStr::from_ptr(error.as_ptr()) }.to_string_lossy().into_owned();
            if detail.is_empty() { Err(AnimeError::Cancelled) } else { Err(AnimeError::Native { detail }) }
        }
        #[cfg(not(anima_native))]
        {
            let _ = (paths, seed, threads);
            Err(AnimeError::Unavailable)
        }
    }
}

impl Drop for AnimaJob {
    fn drop(&mut self) {
        #[cfg(anima_native)]
        unsafe { native::koharu_anima_job_free(self.pointer) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_anima_config_is_valid() {
        let config = anima_config().unwrap();
        assert_eq!(config.components.len(), 3);
        assert_eq!((config.width, config.height, config.steps), (512, 512, 6));
    }
}
