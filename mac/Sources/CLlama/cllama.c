#include "cllama.h"
#include "llama.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// Targets the llama.cpp C API as of the tag pinned in build.sh (the high-level
// helpers: llama_model_load_from_file / llama_init_from_model / the sampler
// chain / llama_batch_get_one). If a future bump renames these, this file is the
// only place to adjust.

struct cllama_ctx {
  struct llama_model *model;
  struct llama_context *ctx;
  const struct llama_vocab *vocab;
};

static int g_backend_inited = 0;

cllama_ctx *cllama_load(const char *model_path, int n_ctx, int n_gpu_layers) {
  if (!g_backend_inited) {
    llama_backend_init();
    g_backend_inited = 1;
  }

  struct llama_model_params mp = llama_model_default_params();
  mp.n_gpu_layers = n_gpu_layers;
  struct llama_model *model = llama_model_load_from_file(model_path, mp);
  if (!model) return NULL;

  struct llama_context_params cp = llama_context_default_params();
  cp.n_ctx = (uint32_t)n_ctx;
  cp.n_batch = (uint32_t)n_ctx;
  struct llama_context *ctx = llama_init_from_model(model, cp);
  if (!ctx) {
    llama_model_free(model);
    return NULL;
  }

  cllama_ctx *h = (cllama_ctx *)calloc(1, sizeof(cllama_ctx));
  h->model = model;
  h->ctx = ctx;
  h->vocab = llama_model_get_vocab(model);
  return h;
}

// Gemma 4 ships an 18 KB Jinja-macro template that llama_chat_apply_template
// (no Jinja parser) rejects outright, and feeding Gemma the ChatML fallback made
// it echo <|im_end|> as plain text, which is not an EOG token for it, so
// decoding ran on into repeats and hallucination. Its turns are simple enough to
// emit directly: <|turn> opens, <turn|> (id 106, EOG) closes.
static char *gemma4_chat(const char *system, const char *user) {
  size_t need = (system ? strlen(system) : 0) + strlen(user) + 128;
  char *buf = (char *)malloc(need);
  if (!buf) return NULL;
  if (system && *system) {
    snprintf(buf, need,
             "<|turn>system\n%s<turn|>\n<|turn>user\n%s<turn|>\n<|turn>model\n",
             system, user);
  } else {
    snprintf(buf, need, "<|turn>user\n%s<turn|>\n<|turn>model\n", user);
  }
  return buf;
}

// NULL when the GGUF carries no template llama.cpp recognizes; callers fall
// back to ChatML.
static char *format_chat(const struct llama_model *model, const char *system,
                         const char *user) {
  const char *tmpl = llama_model_chat_template(model, NULL);
  if (!tmpl || !user) return NULL;

  struct llama_chat_message msgs[2];
  size_t n = 0;
  if (system && *system) {
    msgs[n].role = "system";
    msgs[n].content = system;
    n++;
  }
  msgs[n].role = "user";
  msgs[n].content = user;
  n++;

  int cap = (int)((system ? strlen(system) : 0) + strlen(user)) * 2 + 1024;
  char *buf = (char *)malloc((size_t)cap);
  if (!buf) return NULL;
  int len = llama_chat_apply_template(tmpl, msgs, n, true, buf, cap);
  if (len >= cap) {
    char *bigger = (char *)realloc(buf, (size_t)len + 1);
    if (!bigger) {
      free(buf);
      return NULL;
    }
    buf = bigger;
    len = llama_chat_apply_template(tmpl, msgs, n, true, buf, len + 1);
  }
  if (len < 0) {
    free(buf);
    return strstr(tmpl, "<|turn>") ? gemma4_chat(system, user) : NULL;
  }
  buf[len] = '\0';
  return buf;
}

static char *chatml(const char *system, const char *user) {
  size_t need = (system ? strlen(system) : 0) + strlen(user) + 128;
  char *buf = (char *)malloc(need);
  if (!buf) return NULL;
  snprintf(buf, need,
           "<|im_start|>system\n%s<|im_end|>\n<|im_start|>user\n%s<|im_end|>\n"
           "<|im_start|>assistant\n",
           system ? system : "", user);
  return buf;
}

static char *generate_raw(cllama_ctx *h, const char *prompt, int max_tokens,
                          float temperature) {
  if (!h || !prompt) return NULL;
  const struct llama_vocab *vocab = h->vocab;
  const int prompt_len = (int)strlen(prompt);

  // Tokenize (add_special + parse_special so Gemma's <start_of_turn> markers and
  // BOS are handled). First call with NULL returns -needed.
  int n_prompt = -llama_tokenize(vocab, prompt, prompt_len, NULL, 0, true, true);
  if (n_prompt <= 0) return NULL;
  llama_token *tokens = (llama_token *)malloc(sizeof(llama_token) * n_prompt);
  if (llama_tokenize(vocab, prompt, prompt_len, tokens, n_prompt, true, true) < 0) {
    free(tokens);
    return NULL;
  }

  // Each call is a fresh chat, and llama_decode aborts (not errors) on a batch past n_batch.
  llama_memory_clear(llama_get_memory(h->ctx), true);
  const int n_ctx = (int)llama_n_ctx(h->ctx);
  if (n_prompt >= n_ctx) {
    free(tokens);
    return NULL;
  }
  if (max_tokens > n_ctx - n_prompt) max_tokens = n_ctx - n_prompt;

  // Sampler chain: greedy when temperature<=0, else top-k/top-p/temp/dist.
  struct llama_sampler *smpl =
      llama_sampler_chain_init(llama_sampler_chain_default_params());
  if (temperature <= 0.0f) {
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
  } else {
    llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
  }

  size_t cap = 4096, len = 0;
  char *out = (char *)malloc(cap);
  out[0] = '\0';

  struct llama_batch batch = llama_batch_get_one(tokens, n_prompt);
  llama_token cur = 0;
  int generated = 0;
  int ok = 1;
  while (generated < max_tokens) {
    if (llama_decode(h->ctx, batch) != 0) {
      ok = 0;
      break;
    }
    cur = llama_sampler_sample(smpl, h->ctx, -1);
    if (llama_vocab_is_eog(vocab, cur)) break;

    // Never render control tokens: one that is not flagged EOG would otherwise
    // land in the user's transcript verbatim.
    char piece[256];
    int np = llama_token_to_piece(vocab, cur, piece, (int)sizeof(piece), 0, false);
    if (np < 0) {
      ok = 0;
      break;
    }
    if (len + (size_t)np + 1 > cap) {
      cap *= 2;
      out = (char *)realloc(out, cap);
    }
    memcpy(out + len, piece, (size_t)np);
    len += (size_t)np;
    out[len] = '\0';

    batch = llama_batch_get_one(&cur, 1);
    generated++;
  }

  llama_sampler_free(smpl);
  free(tokens);
  if (!ok && len == 0) {
    free(out);
    return NULL;
  }
  return out;
}

char *cllama_chat(cllama_ctx *h, const char *system, const char *user,
                  int max_tokens, float temperature) {
  if (!h || !user) return NULL;
  char *prompt = format_chat(h->model, system, user);
  if (!prompt) prompt = chatml(system, user);
  if (!prompt) return NULL;
  char *out = generate_raw(h, prompt, max_tokens, temperature);
  free(prompt);
  return out;
}

void cllama_free_str(char *s) { free(s); }

void cllama_free(cllama_ctx *h) {
  if (!h) return;
  if (h->ctx) llama_free(h->ctx);
  if (h->model) llama_model_free(h->model);
  free(h);
}

// --- Audio ASR via mtmd ---

#include "mtmd.h"
#include "mtmd-helper.h"
#include <stdio.h>

struct cllama_asr {
  struct llama_model *model;
  struct llama_context *lctx;
  const struct llama_vocab *vocab;
  mtmd_context *mctx;
  llama_logit_bias *no_deva; // every Devanagari token, banned
  int n_no_deva;
};

// A Latin-script transcript that comes back in Devanagari is the recognizer
// slipping, and no instruction stops it. Banning the tokens does. Built once
// per model: UTF-8 U+0900..U+097F is E0 A4 80 .. E0 A5 BF.
static void build_deva_ban(struct cllama_asr *h) {
  int n_vocab = llama_vocab_n_tokens(h->vocab);
  h->no_deva = (llama_logit_bias *)malloc(sizeof(llama_logit_bias) * (size_t)n_vocab);
  if (!h->no_deva) return;
  h->n_no_deva = 0;
  for (int t = 0; t < n_vocab; t++) {
    char piece[256];
    int n = llama_token_to_piece(h->vocab, t, piece, (int)sizeof(piece), 0, false);
    for (int i = 0; i + 1 < n; i++) {
      unsigned char a = (unsigned char)piece[i], b = (unsigned char)piece[i + 1];
      if (a == 0xE0 && (b == 0xA4 || b == 0xA5)) {
        h->no_deva[h->n_no_deva].token = t;
        h->no_deva[h->n_no_deva].bias = -INFINITY;
        h->n_no_deva++;
        break;
      }
    }
  }
}

cllama_asr *cllama_asr_load(const char *model_path, const char *mmproj_path) {
  if (!g_backend_inited) {
    llama_backend_init();
    g_backend_inited = 1;
  }
  struct llama_model_params mp = llama_model_default_params();
  mp.n_gpu_layers = 999;
  struct llama_model *model = llama_model_load_from_file(model_path, mp);
  if (!model) return NULL;

  struct llama_context_params cp = llama_context_default_params();
  cp.n_ctx = 4096;
  cp.n_batch = 2048;
  struct llama_context *lctx = llama_init_from_model(model, cp);
  if (!lctx) {
    llama_model_free(model);
    return NULL;
  }

  struct mtmd_context_params mparams = mtmd_context_params_default();
  mparams.use_gpu = true;
  mparams.print_timings = false;
  mparams.n_threads = 4;
  mtmd_context *mctx = mtmd_init_from_file(mmproj_path, model, mparams);
  if (!mctx) {
    llama_free(lctx);
    llama_model_free(model);
    return NULL;
  }

  cllama_asr *h = (cllama_asr *)calloc(1, sizeof(cllama_asr));
  h->model = model;
  h->lctx = lctx;
  h->vocab = llama_model_get_vocab(model);
  h->mctx = mctx;
  return h;
}

char *cllama_asr_transcribe(cllama_asr *h, const float *samples, int n_samples,
                            int sample_rate, int max_tokens,
                            const char *instruction, int latin_only) {
  if (!h || !samples || n_samples <= 0 || sample_rate <= 0) return NULL;

  int target = mtmd_get_audio_sample_rate(h->mctx);
  if (target <= 0) target = 16000;
  float *resampled = NULL;
  int n_pcm = n_samples;
  const float *pcm = samples;
  if (sample_rate != target) {
    double ratio = (double)target / (double)sample_rate;
    n_pcm = (int)((double)n_samples * ratio);
    if (n_pcm <= 0) return NULL;
    resampled = (float *)malloc(sizeof(float) * (size_t)n_pcm);
    for (int i = 0; i < n_pcm; i++) {
      double src = (double)i / ratio;
      int i0 = (int)src;
      int i1 = i0 + 1 < n_samples ? i0 + 1 : i0;
      double f = src - (double)i0;
      resampled[i] = (float)((double)samples[i0] * (1.0 - f) + (double)samples[i1] * f);
    }
    pcm = resampled;
  }

  // Fresh KV state per utterance, one-shot transcription, no chat history.
  llama_memory_clear(llama_get_memory(h->lctx), true);

  char *out = NULL;
  char *user = NULL;
  char *prompt = NULL;
  mtmd_bitmap *bmp = mtmd_bitmap_init_from_audio((size_t)n_pcm, pcm);
  mtmd_input_chunks *chunks = mtmd_input_chunks_init();
  if (!bmp || !chunks) goto done;

  // The instruction leads the user turn and the media marker closes it, so the
  // audio is the last thing before generation. mtmd expands the marker into the
  // model's audio_start/pad/end structure. Ordering matters: a system turn was
  // too weak to fix spellings, and putting the instruction after the audio made
  // the model carry on from it and echo the vocabulary list into the transcript.
  const char *marker = mtmd_default_marker();
  if (instruction && *instruction) {
    size_t need = strlen(marker) + strlen(instruction) + 2;
    user = (char *)malloc(need);
    if (!user) goto done;
    snprintf(user, need, "%s\n%s", instruction, marker);
  } else {
    user = strdup(marker);
    if (!user) goto done;
  }
  prompt = format_chat(h->model, NULL, user);
  if (!prompt) prompt = chatml("", user);
  if (!prompt) goto done;

  struct mtmd_input_text txt = {
    .text = prompt,
    .text_len = strlen(prompt),
    .add_special = true,
    .parse_special = true,
  };
  const mtmd_bitmap *bmps[1] = { bmp };
  if (mtmd_tokenize(h->mctx, chunks, &txt, bmps, 1) != 0) goto done;

  llama_pos n_past = 0;
  if (mtmd_helper_eval_chunks(h->mctx, h->lctx, chunks, 0, 0, 2048, true,
                              &n_past) != 0) goto done;

  struct llama_sampler *smpl =
      llama_sampler_chain_init(llama_sampler_chain_default_params());
  if (latin_only) {
    if (!h->no_deva) build_deva_ban(h);
    if (h->n_no_deva > 0) {
      llama_sampler_chain_add(smpl, llama_sampler_init_logit_bias(
          llama_vocab_n_tokens(h->vocab), h->n_no_deva, h->no_deva));
    }
  }
  llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

  size_t cap = 4096, len = 0;
  out = (char *)malloc(cap);
  out[0] = '\0';
  for (int g = 0; g < max_tokens; g++) {
    llama_token cur = llama_sampler_sample(smpl, h->lctx, -1);
    if (llama_vocab_is_eog(h->vocab, cur)) break;
    char piece[256];
    int np = llama_token_to_piece(h->vocab, cur, piece, (int)sizeof(piece), 0, false);
    if (np < 0) break;
    if (len + (size_t)np + 1 > cap) {
      cap *= 2;
      out = (char *)realloc(out, cap);
    }
    memcpy(out + len, piece, (size_t)np);
    len += (size_t)np;
    out[len] = '\0';
    struct llama_batch b = llama_batch_get_one(&cur, 1);
    if (llama_decode(h->lctx, b) != 0) break;
  }
  llama_sampler_free(smpl);

done:
  if (chunks) mtmd_input_chunks_free(chunks);
  if (bmp) mtmd_bitmap_free(bmp);
  free(prompt);
  free(user);
  free(resampled);
  return out;
}

void cllama_asr_free(cllama_asr *h) {
  if (!h) return;
  free(h->no_deva);
  if (h->mctx) mtmd_free(h->mctx);
  if (h->lctx) llama_free(h->lctx);
  if (h->model) llama_model_free(h->model);
  free(h);
}
