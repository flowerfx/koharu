#include "VisionNative.h"
#include <stable_diffusion/stable-diffusion.h>
#include <stable_diffusion/sd_dart_wrapper.h>
#include <string>
#include <vector>
#include <memory>
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <cmath>
#include <mutex>
#include <atomic>

static void report(char *out, size_t n, const char *message) { if (out && n) snprintf(out, n, "%s", message ? message : "Native vision error"); }
struct DiffusionHandle { sd_ctx_t *context = nullptr; bool flux; ~DiffusionHandle() { if (context) sd_dart_exit_free(context); } };
void *koharu_diffusion_open(const char *directory, int flux, char *error, size_t capacity) {
    auto handle = std::make_unique<DiffusionHandle>(); handle->flux = flux;
    std::string root = directory, denoiser = root + "/diffusion.gguf", vae = root + "/vae.safetensors";
    std::string text = root + "/text.gguf", marker = root + "/marker.safetensors", clip_l = root + "/clip_l.safetensors", clip_g = root + "/clip_g.safetensors";
    sd_ctx_params_t params; sd_ctx_params_init(&params);
    params.diffusion_model_path = denoiser.c_str(); params.vae_path = vae.c_str();
    params.enable_mmap = true; params.n_threads = 4; params.backend = nullptr;
    // Stage weights from mmap'd CPU storage instead of retaining two full model
    // copies on the unified-memory GPU. The runtime handles segmented compute.
    params.params_backend = "*=cpu"; params.auto_fit = true; params.max_vram = "2.5"; params.disable_prefetch = true;
    if (flux) { params.llm_path = text.c_str(); params.vae_format = SD_VAE_FORMAT_FLUX2; }
    else { params.model_path = marker.c_str(); params.clip_l_path = clip_l.c_str(); params.clip_g_path = clip_g.c_str(); }
    handle->context = sd_dart_new_sd_ctx(&params);
    if (!handle->context) { sd_dart_last_error(error, capacity); return nullptr; }
    return handle.release();
}
int koharu_diffusion_run(void *opaque, const uint8_t *rgb, const uint8_t *mask, int edge, uint8_t *output, char *error, size_t capacity) {
    auto *handle = static_cast<DiffusionHandle *>(opaque);
    if (!handle || !handle->context || edge < 64 || edge > 1024) return 0;
    sd_img_gen_params_t params; sd_img_gen_params_init(&params);
    params.init_image = {(uint32_t)edge, (uint32_t)edge, 3, const_cast<uint8_t *>(rgb)};
    params.mask_image = {(uint32_t)edge, (uint32_t)edge, 1, const_cast<uint8_t *>(mask)};
    params.width = edge; params.height = edge; params.seed = 42; params.batch_count = 1;
    params.prompt = handle->flux ? "Remove the text and reconstruct the background." : "clean manga illustration, crisp black line art, flat colors, seamless original background, clean white speech bubble, no text";
    params.negative_prompt = handle->flux ? "" : "text, letters, words, symbols, watermark, signature, blurry, smudged, dirty, gray artifacts, extra objects, photorealistic";
    params.sample_params.sample_method = EULER_SAMPLE_METHOD;
    params.sample_params.scheduler = handle->flux ? FLUX2_SCHEDULER : DISCRETE_SCHEDULER;
    params.sample_params.sample_steps = handle->flux ? 4 : 30;
    params.sample_params.guidance.txt_cfg = handle->flux ? 1.0f : 8.0f;
    params.strength = handle->flux ? std::nextafter(1.0f, 0.0f) : 0.999f;
    if (handle->flux) { params.ref_images = &params.init_image; params.ref_images_count = 1; params.ref_image_args = "resize_before_vae=0"; }
    params.vae_tiling_params.enabled = true; params.vae_tiling_params.tile_size_w = 256; params.vae_tiling_params.tile_size_h = 256;
    sd_image_t *images = nullptr; int count = 0;
    bool ok = sd_dart_generate_image(handle->context, &params, &images, &count);
    if (!ok || count != 1 || !images || images[0].width != edge || images[0].height != edge || images[0].channel != 3 || !images[0].data) {
        sd_dart_last_error(error, capacity); if (images) free_sd_images(images, count); return 0;
    }
    memcpy(output, images[0].data, (size_t)edge * edge * 3); free_sd_images(images, count); return 1;
}
void koharu_diffusion_close(void *handle) { delete static_cast<DiffusionHandle *>(handle); }

// A job outlives loading, generation and cooperative cancellation. The mutex
// prevents cancellation racing context teardown; loading itself is not cancelable.
struct AnimaJob {
    std::mutex mutex;
    sd_ctx_t *context = nullptr;
    std::atomic<bool> cancelled{false};
    std::atomic<uint64_t> sequence{0};
    std::atomic<bool> progress_ready{false};
    std::atomic<int> phase{0};
};
void *koharu_anima_job_new(void) { return new (std::nothrow) AnimaJob(); }
void koharu_anima_job_free(void *job) { delete static_cast<AnimaJob *>(job); }
void koharu_anima_job_cancel(void *opaque) {
    auto *job = static_cast<AnimaJob *>(opaque);
    if (!job) return;
    job->cancelled = true;
    std::lock_guard<std::mutex> lock(job->mutex);
    if (job->context) sd_dart_cancel_generation(job->context, SD_CANCEL_ALL);
}
int koharu_anima_job_progress(void *opaque, int *step, int *steps) {
    auto *job = static_cast<AnimaJob *>(opaque);
    *step = 0; *steps = 0;
    if (!job) return 0;
    if (!job->progress_ready) return job->phase;
    sd_dart_progress_t reports[64];
    size_t count = sd_dart_progress_read(job->sequence, reports, 64, nullptr);
    if (count) {
        auto &last = reports[count - 1];
        job->sequence = last.sequence;
        *step = last.step; *steps = last.steps;
    }
    return job->phase;
}
int koharu_anima_generate(void *opaque, const char *diffusion, const char *text, const char *vae,
                          const char *prompt, int width, int height, int steps, int64_t seed,
                          uint8_t *output, char *error, size_t capacity) {
    auto *job = static_cast<AnimaJob *>(opaque);
    bool supported_size = (width == 512 && height == 512) || (width == 768 && height == 1024) ||
                          (width == 720 && height == 1280) || (width == 1024 && height == 1024) ||
                          (width == 1024 && height == 1280);
    if (!job || !prompt || !*prompt || !output || !supported_size || steps < 5 || steps > 20) {
        report(error, capacity, "Invalid anime generation request"); return 0;
    }
    try {
        if (job->cancelled) return 0;
        job->phase = 1;
        std::string metal;
        for (int i = 0; i < sd_dart_gpu_device_count(); ++i) {
            sd_dart_gpu_device_memory_t device{};
            if (sd_dart_gpu_device_memory(i, &device) == SD_DART_GPU_OK &&
                (strncmp(device.name, "MTL", 3) == 0 || strncmp(device.name, "Metal", 5) == 0)) {
                metal = device.name; break;
            }
        }
        if (metal.empty()) { report(error, capacity, "Metal is not available on this device"); return 0; }
        sd_dart_progress_enable();
        job->progress_ready = false;
        uint64_t latest = 0; sd_dart_progress_read(0, nullptr, 0, &latest); job->sequence = latest;
        job->progress_ready = true;
        sd_ctx_params_t context; sd_ctx_params_init(&context);
        context.diffusion_model_path = diffusion; context.llm_path = text; context.vae_path = vae;
        context.backend = metal.c_str(); context.params_backend = "*=cpu";
        context.enable_mmap = true; context.n_threads = 4;
        context.max_vram = "2.5"; context.disable_prefetch = true; context.flash_attn = true;
        std::unique_ptr<sd_ctx_t, decltype(&sd_dart_exit_free)> runtime(sd_dart_new_sd_ctx(&context), sd_dart_exit_free);
        if (!runtime) { sd_dart_last_error(error, capacity); if (!error[0]) report(error, capacity, "Could not load Anima model"); return 0; }
        std::unique_lock<std::mutex> lock(job->mutex);
        if (job->cancelled) return 0;
        job->context = runtime.get(); lock.unlock();
        // Clear the pointer before runtime is freed, including on exceptions.
        struct ClearContext {
            AnimaJob *job;
            ~ClearContext() { std::lock_guard<std::mutex> guard(job->mutex); job->context = nullptr; }
        } clear{job};
        sd_img_gen_params_t params; sd_img_gen_params_init(&params);
        params.prompt = prompt; params.negative_prompt = "";
        params.width = width; params.height = height; params.seed = seed; params.batch_count = 1;
        params.sample_params.sample_method = EULER_SAMPLE_METHOD;
        params.sample_params.scheduler = SGM_UNIFORM_SCHEDULER;
        params.sample_params.sample_steps = steps; params.sample_params.guidance.txt_cfg = 1.0f;
        params.vae_tiling_params.enabled = true;
        params.vae_tiling_params.tile_size_w = 256; params.vae_tiling_params.tile_size_h = 256;
        sd_image_t *images = nullptr; int count = 0;
        struct ImageBatch {
            sd_image_t *&images; int &count;
            ~ImageBatch() { if (images) free_sd_images(images, count); }
        } batch{images, count};
        if (job->cancelled) return 0;
        job->phase = 2;
        bool ok = sd_dart_generate_image(runtime.get(), &params, &images, &count);
        bool valid = ok && !job->cancelled && count == 1 && images && images[0].data &&
                     images[0].width == (uint32_t)width && images[0].height == (uint32_t)height && images[0].channel == 3;
        if (valid) memcpy(output, images[0].data, (size_t)width * height * 3);
        else { sd_dart_last_error(error, capacity); if (!error[0]) report(error, capacity, "Could not generate anime image"); }
        if (valid) job->phase = 3;
        return valid ? 1 : 0;
    } catch (const std::exception &e) { report(error, capacity, e.what()); return 0; }
}

#if __has_include(<llama/mtmd.h>)
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>
struct PaddleHandle {
    llama_model *model = nullptr; llama_context *context = nullptr; mtmd_context *vision = nullptr;
    ~PaddleHandle() { if (vision) mtmd_free(vision); if (context) llama_free(context); if (model) llama_model_free(model); }
};
void *koharu_paddle_open(const char *directory, char *error, size_t capacity) {
    // llama_backend_init is idempotent and shared with the translation runtime.
    llama_backend_init(); auto handle = std::make_unique<PaddleHandle>();
    auto model_params = llama_model_default_params(); model_params.n_gpu_layers = 99;
    handle->model = llama_model_load_from_file((std::string(directory) + "/model.gguf").c_str(), model_params);
    if (handle->model) {
        auto ctx = llama_context_default_params(); ctx.n_ctx = 4096; ctx.n_batch = 512; ctx.n_ubatch = 128; ctx.n_threads = 4;
        handle->context = llama_init_from_model(handle->model, ctx);
        auto vision = mtmd_context_params_default(); vision.use_gpu = true; vision.n_threads = 4;
        handle->vision = mtmd_init_from_file((std::string(directory) + "/mmproj.gguf").c_str(), handle->model, vision);
    }
    if (!handle->model || !handle->context || !handle->vision) { report(error, capacity, "PaddleOCR GGUF/projector could not be loaded"); return nullptr; }
    return handle.release();
}
int koharu_paddle_read(void *opaque, const uint8_t *rgb, int width, int height, char *output, size_t capacity) {
    auto *handle = static_cast<PaddleHandle *>(opaque); if (!handle || !output || !capacity) return 0;
    llama_memory_clear(llama_get_memory(handle->context), true);
    // Exact single-user rendering of tokenizer.chat_template in PaddlePaddle/
    // PaddleOCR-VL-1.6-GGUF@511b09642bb324401f15f97cc23bc67e8f0a291d.
    // llama's public minja-free C formatter cannot render this Jinja template.
    const std::string prompt = std::string("<|begin_of_sentence|>User: ") + mtmd_default_marker() + "OCR:\nAssistant:\n";
    std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)> bitmap(mtmd_bitmap_init(width, height, rgb), mtmd_bitmap_free);
    std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(mtmd_input_chunks_init(), mtmd_input_chunks_free);
    mtmd_input_text input = {prompt.c_str(), prompt.size(), true, true}; const mtmd_bitmap *images[] = {bitmap.get()};
    if (!bitmap || mtmd_tokenize(handle->vision, chunks.get(), &input, images, 1)) { report(output, capacity, "PaddleOCR image tokenization failed"); return 0; }
    llama_pos past = 0;
    if (mtmd_helper_eval_chunks(handle->vision, handle->context, chunks.get(), 0, 0, 512, true, &past)) { report(output, capacity, "PaddleOCR image encoding failed"); return 0; }
    const llama_vocab *vocab = llama_model_get_vocab(handle->model);
    auto chain_params = llama_sampler_chain_default_params(); std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(chain_params), llama_sampler_free);
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 512, 1.2f, 0, 0)); llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
    std::string text; bool ended = false;
    for (int i = 0; i < 512 && past < 4095; ++i) {
        llama_token token = llama_sampler_sample(sampler.get(), handle->context, -1);
        if (llama_vocab_is_eog(vocab, token)) { ended = true; break; }
        char piece[1024]; int n = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (n < 0 || text.size() + n >= capacity) break;
        text.append(piece, n);
        auto batch = llama_batch_get_one(&token, 1);
        if (llama_decode(handle->context, batch)) break;
        ++past;
    }
    if (!ended) { report(output, capacity, "PaddleOCR did not finish within the output/context limit"); return 0; }
    report(output, capacity, text.c_str()); return 1;
}
void koharu_paddle_close(void *handle) { delete static_cast<PaddleHandle *>(handle); }
#else
void *koharu_paddle_open(const char *, char *error, size_t n) { report(error, n, "PaddleOCR GGUF requires a physical iPad/iPhone"); return nullptr; }
int koharu_paddle_read(void *, const uint8_t *, int, int, char *, size_t) { return 0; }
void koharu_paddle_close(void *) {}
#endif
