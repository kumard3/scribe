#include "cllama.h"
#include "llama.h"

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

char *cllama_generate(cllama_ctx *h, const char *prompt, int max_tokens,
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

    char piece[256];
    int np = llama_token_to_piece(vocab, cur, piece, (int)sizeof(piece), 0, true);
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

void cllama_free_str(char *s) { free(s); }

void cllama_free(cllama_ctx *h) {
  if (!h) return;
  if (h->ctx) llama_free(h->ctx);
  if (h->model) llama_model_free(h->model);
  free(h);
}
