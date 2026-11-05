#ifndef KOHARU_VISION_NATIVE_H
#define KOHARU_VISION_NATIVE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *koharu_diffusion_open(const char *directory, int flux, char *error, size_t capacity);
int koharu_diffusion_run(void *handle, const uint8_t *rgb, const uint8_t *mask, int edge, uint8_t *output, char *error, size_t capacity);
void koharu_diffusion_close(void *handle);
void *koharu_anima_job_new(void);
void koharu_anima_job_cancel(void *job);
// Phase: 0 = preparing, 1 = loading, 2 = generating, 3 = complete, 4 = upscaling.
int koharu_anima_job_progress(void *job, int *step, int *steps);
void koharu_anima_job_free(void *job);
int koharu_anima_generate(void *job, const char *diffusion, const char *text, const char *vae,
                          const char *prompt, int width, int height, int steps, int64_t seed,
                          uint8_t *output, char *error, size_t capacity);
int koharu_anima_upscale(void *job, const char *model, const uint8_t *rgb, int width, int height,
                         int scale, uint8_t *output, size_t output_capacity, char *error, size_t capacity);
void *koharu_paddle_open(const char *directory, char *error, size_t capacity);
int koharu_paddle_read(void *handle, const uint8_t *rgb, int width, int height, char *output, size_t capacity);
void koharu_paddle_close(void *handle);
// Writes a copy of an ONNX model with its free dimension `batch` fixed to 1.
int koharu_onnx_fix_batch(const char *source, const char *target, char *error, size_t capacity);
// Rewrites the ops ONNX Runtime's Core ML EP cannot place into exact equivalents (OnnxRewrite.cpp).
int koharu_onnx_rewrite_coreml(const char *source, const char *target, char *error, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
