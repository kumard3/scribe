#ifndef CLLAMA_H
#define CLLAMA_H

// Minimal C shim over llama.cpp for Scribe's on-device text AI (Gemma 4).
// Keeps the churny llama.h surface out of Swift — Swift sees only these four
// functions and an opaque handle.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cllama_ctx cllama_ctx;

// Load a GGUF model. n_gpu_layers: 999 = offload everything to Metal.
// Returns NULL on failure.
cllama_ctx *cllama_load(const char *model_path, int n_ctx, int n_gpu_layers);

// Generate a completion for `prompt`. Returns a malloc'd UTF-8 C string the
// caller must free with cllama_free_str(). Returns NULL on failure.
char *cllama_generate(cllama_ctx *h, const char *prompt, int max_tokens,
                      float temperature);

void cllama_free_str(char *s);
void cllama_free(cllama_ctx *h);

// --- Audio ASR via mtmd (Qwen3-ASR-style models, e.g. Srota Hinglish) ---

typedef struct cllama_asr cllama_asr;

// Load a Qwen3-ASR GGUF pair: the LLM model + its mmproj audio encoder.
// Returns NULL on failure.
cllama_asr *cllama_asr_load(const char *model_path, const char *mmproj_path);

// Transcribe mono float PCM. Resamples internally to the model's rate.
// Returns a malloc'd UTF-8 string to free with cllama_free_str(), NULL on failure.
char *cllama_asr_transcribe(cllama_asr *h, const float *samples, int n_samples,
                            int sample_rate, int max_tokens);

void cllama_asr_free(cllama_asr *h);

#ifdef __cplusplus
}
#endif

#endif // CLLAMA_H
