#ifndef CLLAMA_H
#define CLLAMA_H

// Minimal C shim over llama.cpp for Scribe's on-device text AI (Gemma 4).
// Keeps the churny llama.h surface out of Swift, Swift sees only these four
// functions and an opaque handle.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cllama_ctx cllama_ctx;

// Load a GGUF model. n_gpu_layers: 999 = offload everything to Metal.
// Returns NULL on failure.
cllama_ctx *cllama_load(const char *model_path, int n_ctx, int n_gpu_layers);

// Run one system+user exchange through the model's own chat template (Gemma,
// ChatML, …), falling back to ChatML when the GGUF carries none. Returns a
// malloc'd UTF-8 C string the caller must free with cllama_free_str(), or NULL.
char *cllama_chat(cllama_ctx *h, const char *system, const char *user,
                  int max_tokens, float temperature);

void cllama_free_str(char *s);
void cllama_free(cllama_ctx *h);

// Embedding model (EmbeddingGemma GGUF), CPU, mean pooling. Free with cllama_free().
cllama_ctx *cllama_embed_load(const char *model_path, int n_ctx);

// Pooled embedding of `text` (prompt already applied) into `out`, at most `cap`
// floats. Returns the model's embedding size, or -1 on failure.
int cllama_embed(cllama_ctx *h, const char *text, float *out, int cap);

// --- Audio ASR via mtmd (Srota / Qwen3-ASR, Gemma 4 E2B & E4B) ---

typedef struct cllama_asr cllama_asr;

// Load an audio GGUF pair: the LLM model + its mmproj audio encoder.
// Returns NULL on failure.
cllama_asr *cllama_asr_load(const char *model_path, const char *mmproj_path);

// Transcribe mono float PCM. Resamples internally to the model's rate.
// `instruction` is the text sent alongside the audio; NULL or "" sends the audio
// alone, which is what dedicated ASR models expect. General-purpose omni models
// (Gemma 4) need to be told to transcribe.
// Returns a malloc'd UTF-8 string to free with cllama_free_str(), NULL on failure.
// `latin_only` bans every Devanagari token, the one thing that reliably stops
// the model writing spoken English in Devanagari.
char *cllama_asr_transcribe(cllama_asr *h, const float *samples, int n_samples,
                            int sample_rate, int max_tokens,
                            const char *instruction, int latin_only);

void cllama_asr_free(cllama_asr *h);

#ifdef __cplusplus
}
#endif

#endif // CLLAMA_H
