// Anima (stable-diffusion.cpp) job for Android, ported from the iPad
// koharu_anima_* functions in apps/ipad/Sources/VisionNative.cpp. The pinned
// stable-diffusion-native Android runtime is CPU-only, so the Metal backend
// selection and the VAE-on-CPU split of the iPad port are dropped; sampling
// parameters are unchanged.

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sd_dart_wrapper.h"
#include "stable-diffusion.h"

// A job outlives loading, generation and cooperative cancellation. The mutex
// prevents cancellation racing context teardown; loading itself is not cancelable.
typedef struct {
    pthread_mutex_t mutex;
    sd_ctx_t *context;
    atomic_bool cancelled;
    atomic_bool progress_ready;
    atomic_int phase;
    uint64_t sequence;
} anima_job;

static void report(char *error, size_t capacity, const char *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message);
}

void *koharu_anima_job_new(void) {
    anima_job *job = calloc(1, sizeof(anima_job));
    if (!job) return NULL;
    pthread_mutex_init(&job->mutex, NULL);
    return job;
}

void koharu_anima_job_free(void *opaque) {
    anima_job *job = opaque;
    if (!job) return;
    pthread_mutex_destroy(&job->mutex);
    free(job);
}

void koharu_anima_job_cancel(void *opaque) {
    anima_job *job = opaque;
    if (!job) return;
    atomic_store(&job->cancelled, true);
    pthread_mutex_lock(&job->mutex);
    if (job->context) sd_dart_cancel_generation(job->context, SD_CANCEL_ALL);
    pthread_mutex_unlock(&job->mutex);
}

// Phase: 0 idle, 1 loading, 2 sampling/decoding, 3 done. Step counters come
// from the runtime's process-wide progress recorder, read from this job's start.
int koharu_anima_job_progress(void *opaque, int *step, int *steps) {
    anima_job *job = opaque;
    *step = 0; *steps = 0;
    if (!job) return 0;
    if (!atomic_load(&job->progress_ready)) return atomic_load(&job->phase);
    sd_dart_progress_t reports[64];
    size_t count = sd_dart_progress_read(job->sequence, reports, 64, NULL);
    if (count) {
        job->sequence = reports[count - 1].sequence;
        *step = reports[count - 1].step; *steps = reports[count - 1].steps;
    }
    return atomic_load(&job->phase);
}

int koharu_anima_generate(void *opaque, const char *diffusion, const char *text, const char *vae,
                          const char *prompt, int width, int height, int steps, int64_t seed, int threads,
                          uint8_t *output, char *error, size_t capacity) {
    anima_job *job = opaque;
    bool supported_size = (width == 512 && height == 512) || (width == 768 && height == 1024) ||
                          (width == 720 && height == 1280) || (width == 1024 && height == 1024) ||
                          (width == 1024 && height == 1280);
    if (!job || !prompt || !*prompt || !output || !supported_size || steps < 5 || steps > 20) {
        report(error, capacity, "Invalid anime generation request"); return 0;
    }
    if (atomic_load(&job->cancelled)) return 0;
    atomic_store(&job->phase, 1);
    sd_dart_progress_enable();
    atomic_store(&job->progress_ready, false);
    uint64_t latest = 0;
    sd_dart_progress_read(0, NULL, 0, &latest);
    job->sequence = latest;
    atomic_store(&job->progress_ready, true);

    sd_ctx_params_t context;
    sd_ctx_params_init(&context);
    context.diffusion_model_path = diffusion; context.llm_path = text; context.vae_path = vae;
    context.enable_mmap = true; context.n_threads = threads > 0 ? threads : sd_get_num_physical_cores();
    context.flash_attn = true;
    sd_ctx_t *runtime = sd_dart_new_sd_ctx(&context);
    if (!runtime) {
        sd_dart_last_error(error, capacity);
        if (!error[0]) report(error, capacity, "Could not load Anima model");
        return 0;
    }
    pthread_mutex_lock(&job->mutex);
    bool stop = atomic_load(&job->cancelled);
    if (!stop) job->context = runtime;
    pthread_mutex_unlock(&job->mutex);
    if (stop) { sd_dart_exit_free(runtime); return 0; }

    sd_img_gen_params_t params;
    sd_img_gen_params_init(&params);
    params.prompt = prompt; params.negative_prompt = "";
    params.width = width; params.height = height; params.seed = seed; params.batch_count = 1;
    params.sample_params.sample_method = EULER_SAMPLE_METHOD;
    params.sample_params.scheduler = SGM_UNIFORM_SCHEDULER;
    params.sample_params.sample_steps = steps; params.sample_params.guidance.txt_cfg = 1.0f;
    params.vae_tiling_params.enabled = true;
    params.vae_tiling_params.tile_size_w = 256; params.vae_tiling_params.tile_size_h = 256;

    sd_image_t *images = NULL;
    int count = 0;
    bool ok = false;
    if (!atomic_load(&job->cancelled)) {
        atomic_store(&job->phase, 2);
        ok = sd_dart_generate_image(runtime, &params, &images, &count);
    }
    bool valid = ok && !atomic_load(&job->cancelled) && count == 1 && images && images[0].data &&
                 images[0].width == (uint32_t)width && images[0].height == (uint32_t)height && images[0].channel == 3;
    if (valid) memcpy(output, images[0].data, (size_t)width * height * 3);
    else if (!atomic_load(&job->cancelled)) {
        sd_dart_last_error(error, capacity);
        if (!error[0]) report(error, capacity, "Could not generate anime image");
    }
    if (images) free_sd_images(images, count);
    // Clear the pointer before the runtime is freed.
    pthread_mutex_lock(&job->mutex);
    job->context = NULL;
    pthread_mutex_unlock(&job->mutex);
    sd_dart_exit_free(runtime);
    if (valid) atomic_store(&job->phase, 3);
    return valid ? 1 : 0;
}
