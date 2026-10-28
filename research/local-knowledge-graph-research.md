# Local knowledge graphs for Bolkit and agent-memory

Research date: 2026-10-02. Target hardware: Apple Silicon Mac with 18 GB RAM (this machine is an M3 Pro), plus phones where possible.

## How to read this report

Every claim carries one of these tags:

- **[V]** verified this session from a primary source (GitHub repo page, arXiv paper, official docs or vendor blog) fetched today.
- **[S]** from a search snippet or a secondary source (blog, aggregator, docs mirror). Plausible, not confirmed against the primary source.
- **[M]** measured by me on this Mac today (Bun 1.4.0, SQLite 3.54.0, M3 Pro, 18 GB).
- **[L]** read directly from your local code.
- **[E]** my estimate or inference. Treat as a hypothesis to measure, not a fact.

Vendor-reported benchmark numbers (Mem0, Zep, Hindsight, EverMind, Cognee, LightRAG authors, LinearRAG authors) are self-reported even when the source is verified. None of them were reproduced here.

---

## 1. TL;DR

1. **Don't adopt a GraphRAG framework. Build a small graph layer on plain SQLite that you own.** Every major framework is Python, needs LLM-heavy indexing, or has changed status in the last 12 months: Microsoft GraphRAG is in maintenance mode [V], Kuzu was archived after Apple bought it [V], Mem0 removed graph memory from its open-source SDK [V], and Zep Community Edition is deprecated [S].
2. **The evidence says graphs help with multi-hop, cross-document and "what changed" questions, and are neutral or worse for simple fact lookup.** GraphRAG-Bench (ICLR 2026) found vanilla RAG with reranking matches or beats GraphRAG on fact retrieval, while HippoRAG 2 led on complex reasoning at about 1K tokens per query, against about 40K for MS GraphRAG global search [V]. So build hybrid search first and add the graph after it.
3. **Indexing can be nearly LLM-free.** LinearRAG (ICLR 2026) builds its graph with spaCy NER plus semantic links and zero LLM tokens, then retrieves with Personalized PageRank. On their benchmarks it beat HippoRAG 2 and LightRAG while indexing 4.6x faster than HippoRAG 2 [V, self-reported]. LazyGraphRAG indexes with NLP noun phrases at "0.1% of the costs of full GraphRAG" [V]. That is the pattern to copy on device.
4. **For meetings you already have the best entity anchors: diarized, user-named speakers.** Add one structured-extraction call per meeting (Apple Foundation Models `@Generable`, which is 8,192 tokens of context on the macOS/iOS 27 on-device model [V]) for decisions, action items and relations. Use GLiNER2 (205M params, CPU, about 335 ms per call on an M3 Pro via the MacPaw Swift/MLX port [V]) only if recall needs it.
5. **Use temporal edges in the Graphiti style.** Each fact gets `valid_from`/`valid_to` plus `recorded_at`/`invalidated_at`, and gets superseded rather than deleted [V]. This is what makes "what did we decide about X, and did it change?" answerable.
6. **Measured on this Mac:** a 2-hop recursive-CTE traversal over 50K nodes and 300K edges in `bun:sqlite` takes 0.16 ms. A brute-force scan of 50K 256-dimension vectors in plain JS takes 9.9 ms. Personalized PageRank over the whole 50K-node graph takes 69 ms [M]. At personal scale you don't need a graph database or a vector extension.
7. **agent-memory today stores JSON files plus a flat `vectors.bin`, not SQLite [L].** Moving it to `bun:sqlite` (FTS5 confirmed working [M]) with temporal edges, provenance and PPR-seeded retrieval is the highest-leverage change. Have the calling coding agent do extraction for free at `memory_store` time.

---

## 2. What your code does today [L]

**Bolkit Mac** (`localvoice/mac/Package.swift`, `Sources/Scribe`):
- It already ships llama.cpp (`CLlama`), MLX Swift LM (Gemma 4 E2B via `MLXRuntime.swift`), ONNX Runtime (linked through sherpa-onnx, headers in `CORT`), swift-transformers, FluidAudio, and FoundationModels (weak-linked, used in `MeetingPipeline.swift` when Apple Intelligence is available). The minimum is macOS 14.
- Meetings are stored as `meeting.json` per directory (`MeetingDetailView.swift`). Dictation history is a string array in `UserDefaults` (`DictationManager.swift`). There's no database yet.
- Transcripts can be Hindi/English code-mixed (the meeting ASR prefers Gemma "for Hindi/English mixes"). This matters a lot for extraction and embedding choices.

**Bolkit mobile** (`localvoice/package.json`): Expo 56, React Native 0.85, `llama.rn` 0.12, `whisper.rn`, `react-native-sherpa-onnx`. There's no SQLite package yet.

**agent-memory** (`agent-memory/src`):
- Storage is JSON (`graph.json`, `index.json` inverted index, `chunks/`) plus a flat Float32 `vectors.bin` with brute-force cosine (`vector-store.ts`). There is no SQLite anywhere in `src`. Your brief said "Bun + SQLite"; the code says otherwise.
- Embeddings use `Xenova/bge-small-en-v1.5` (384-dimension, English-only). Reranking uses `Xenova/ms-marco-MiniLM-L-6-v2`. Retrieval is BM25 plus TF-IDF/embeddings fused with RRF, then 1-2 hop graph enrichment.
- `GraphEdge` is `{source, target, label, createdAt}`. It has no validity interval and no provenance back to the chunk or message that asserted it.
- `repo-map.ts` already implements Personalized PageRank for the code graph, so it can be reused for memory retrieval.
- `eval/eval-set.json` exists. Gate every change below on it.
- `LEARNINGS.md` notes that 99.7% of chunks were raw conversation and that a 44 MB pretty-printed `index.json` caused O(n) rewrite costs. Both point at SQLite.
- The on-disk store is 1.8 GB across 35 projects (`du ~/.agent-memory`).

---

## 3. Graph-RAG and graph-memory frameworks

### 3.1 Does a graph help at all? (evidence first)

- **GraphRAG-Bench, "When to use Graphs in RAG"** (arXiv 2506.05690, ICLR 2026) [V] https://arxiv.org/html/2506.05690v3
  - "Basic RAG is comparable to or outperforms GraphRAG in simple fact retrieval tasks". Vanilla RAG plus reranking reached 83.21% evidence recall on the novel dataset.
  - GraphRAG wins on complex reasoning, contextual summarization and creative generation. HippoRAG 2 led complex reasoning.
  - Prompt tokens per query: MS-GraphRAG global about 40,000, LightRAG about 10,000, HippoRAG 2 about 1,000, vanilla RAG about 879.
- **RAG vs. GraphRAG: A Systematic Evaluation** (arXiv 2502.11371, revised Mar 2026) [S]: the two are complementary, and each wins on different question types. https://arxiv.org/abs/2502.11371
- **Use Graph When It Needs** (arXiv 2602.03578, Feb 2026) [V, abstract-level]: route only complex queries to graph retrieval. https://arxiv.org/pdf/2602.03578
- **Towards Practical GraphRAG** (arXiv 2507.03226, Dec 2025 revision) [V]: KG construction with dependency parsing reaches "94% of LLM-based performance (61.87% vs. 65.83%)". Retrieval is hybrid vector plus 1-hop traversal fused with RRF. https://arxiv.org/abs/2507.03226

**Implication:** for "what did Asha say about pricing", hybrid search (BM25 plus vector plus speaker/time filters) is enough. The graph earns its keep on "everything about project X across 30 meetings", "open action items owned by me", and "did we reverse the decision on Y".

### 3.2 Comparison table

| System | Status (Oct 2026) | License | Indexing LLM cost | Incremental | Local LLM | Fit for you |
|---|---|---|---|---|---|---|
| Microsoft GraphRAG | "largely in maintenance mode", no new features [V] | MIT | Highest: extraction plus community reports. `--method fast` swaps entity extraction for NLTK/spaCy noun phrases [S] | Weak | Possible via OpenAI-compatible endpoints [E] | No |
| LazyGraphRAG | Shipped in Azure/Microsoft Discovery. No open-source release found [V blog, S availability] | n/a | Indexing is NLP-only, "0.1% of the costs of full GraphRAG". LLM runs at query time under a "relevance test budget" [V] | n/a | n/a | Copy the idea |
| LightRAG (HKUDS) | Very active. About 40K stars, v1.5.4 June 2026 [V/S] | MIT | 1 extraction call per chunk plus optional gleaning passes, each "doubling" extraction cost [S]. About 86.7M tokens to index 2Wiki, per the LinearRAG paper [V] | Yes, insert and delete with KG regeneration [V] | Yes, but README says minimum extraction model locally is **Qwen3-30B-A3B-Instruct** [V]. That is roughly 15-17 GB at 4-bit, so it doesn't fit beside other apps on 18 GB [E] | No |
| nano-graphrag | Classified "dying", last commit Jan 2026 [S] | MIT | GraphRAG-like | Partial | Yes | No |
| fast-graphrag (Circlemind) | About 4K stars, last push Nov 2025 [S]. No deprecation notice [V] | MIT | LLM extraction per chunk. PPR retrieval borrowed from HippoRAG [V] | Yes [V] | OpenAI-compatible [V] | Reference only |
| HippoRAG 2 (OSU) | ICML 2025. About 4K stars [V] | MIT | NER plus OpenIE triples per passage. About 6.2M tokens on 2Wiki [V via LinearRAG]. Under $2 with gpt-4o-mini batch [S] | Yes, with tests for incremental and delete [V] | vLLM / Transformers [V] | **Retrieval idea: yes** (PPR over phrase and passage nodes) |
| LinearRAG (PolyU) | ICLR 2026. 553 stars, last update Jan 2026 [V] | **GPL-3.0** [V] | **Zero LLM tokens**: spaCy NER, entity-sentence-passage "Tri-Graph", 249.8 s vs 1,147 s (HippoRAG 2) vs 4,933 s (LightRAG) to index 2Wiki [V, self-reported] | Not documented | Answering only | **Best blueprint for on-device indexing.** Reimplement it; don't vendor GPL code into Bolkit |
| Graphiti (Zep) | About 31K stars. Apache-2.0 [V]. Kuzu driver "deprecated and will be removed" [V] | Apache-2.0 | About 6-10 LLM calls per episode (entity extraction, dedup, fact extraction, summaries) [S] | Yes, the whole point [V] | OpenAI-compatible, but small models "frequently emit JSON that doesn't match the requested schema" [V] | **Temporal model: yes. Library: no** (Python, Neo4j/FalkorDB/Neptune) |
| Zep Community Edition | Deprecated, code moved to `legacy/` [S] | | | | | No |
| Cognee | v1.6.1, 24 Sep 2026. About 31K stars [V] | Apache-2.0 | LLM "cognify" pipeline. Count per chunk not documented [V] | Yes | Ollama [V] | No. Python. Embedded graph is the Kuzu lineage, now documented as "Ladybug/Kuzu" [V] |
| Mem0 (OSS) | **Graph memory removed from the open-source SDK**, "not being replaced by an OSS equivalent". Graph is now a Platform-only feature [V] | Apache-2.0 | 1 LLM call per `add()` in the new algorithm [V] | Yes | Not addressed in docs [V] | No, for graph |
| A-MEM | About 1.2K stars [V] | MIT | Several LLM calls per note (build note, find links, evolve neighbors) [V] | Yes | Ollama [V] | Idea: memory "evolution" of neighbors |
| Letta | Active. "Context Repositories" Feb 2026 [S] | Apache-2.0 | Agent self-edits memory blocks. Sleep-time agent consolidates [V blog] | Yes | Yes | Not a KG. Steal "sleep-time consolidation" |
| txtai | v9.10 June 2026 [S] | Apache-2.0 | Semantic graph from embeddings. LLM extraction optional [S] | Yes | Yes | Python. Reference only |
| KAG (Ant/OpenSPG) | v0.8.0 June 2025, no 2026 release found [V] | Apache-2.0 | Heavy. Requires OpenSPG engine via Docker Compose [V]. "Lightweight build" cuts tokens 89% [V] | | Not documented | No |
| PathRAG | 348 stars, "inactive" about 9 months [S] | None stated [S] | LightRAG-style | | | No |
| MiniRAG (HKUDS) | Last update Feb 2025 [S] | MIT | Heterogeneous chunk-entity graph for small models [V paper] | | Designed for SLMs | Idea only |
| Hindsight (Vectorize) | arXiv 2512.12818. Repo MIT, about 44K stars [V] | MIT | LLM "retain" per item. Recall uses semantic, BM25, graph and temporal search fused with RRF, then cross-encoder rerank [V] | Yes | Ollama, LM Studio, llama.cpp. Embedded `pg0` Postgres [V] | Architecture reference. Postgres-based |
| EverMind EverOS/EverMemOS | Vendor claims 93.05% LoCoMo [S] | Apache-2.0 [S] | LLM | | | Unverified |
| ctxgraph | Small Rust project: one SQLite file with FTS5 and bi-temporal edges. Tiered extraction GLiNER/GLiREL, then local LLM, then cloud [S] | ? | Claims "2.6x fewer LLM calls" than Graphiti at equal F1 (0.638 vs 0.636) [S, unverified, primary page rate-limited] | | | **Closest existing design to what I recommend.** Worth reading |

Benchmark context: Hindsight's own write-up argues LoCoMo and LongMemEval are now saturated, because full-context baselines score competitively with 1M-token models [V] (https://hindsight.vectorize.io/blog/2026/03/23/agent-memory-benchmark). Treat any "SOTA on LoCoMo" claim as weak evidence. Your own eval set matters more.

### 3.3 Notes per framework (only what changes a decision)

- **Microsoft GraphRAG**: the README says it is "largely in maintenance mode... won't be accepting new PRs or implementing new features" and warns that indexing is expensive [V] https://github.com/microsoft/graphrag. LazyGraphRAG [V] https://www.microsoft.com/en-us/research/blog/lazygraphrag-setting-a-new-standard-for-quality-and-cost/ is the important idea. Index with noun-phrase co-occurrence and graph communities, then spend LLM calls only at query time on a budgeted relevance test. I found no open-source LazyGraphRAG code [S].
- **LightRAG** https://github.com/hkuds/lightrag [V]: default local storages (NetworkX, NanoVectorDB, JSON) are "not suitable for production". It recommends BGE-M3 embeddings and the bge-reranker-v2-m3 reranker locally, and 4 LLM roles (EXTRACT, QUERY, KEYWORD, VLM). Gleaning cost [S] https://huggingface.co/spaces/rm-lht/lightrag/blob/89e0b3b6da44b01e54569c309d26d1375407d45f/docs/LightRAG_concurrent_explain.md.
- **HippoRAG 2** https://arxiv.org/pdf/2502.14802, https://github.com/OSU-NLP-Group/HippoRAG [V]: passages and phrases sit in one graph with synonym edges from embedding similarity. Personalized PageRank is seeded from query-matched triples and passages. A 10K-passage corpus yields about 100K phrase nodes and about 1.4M edges [S] https://beancount.io/bean-labs/research-logs/2026/05/07/hipporag-neurobiologically-inspired-long-term-memory-llms.
- **Graphiti** https://github.com/getzep/graphiti [V]: bi-temporal "validity window" per fact with "automatic fact invalidation". Hybrid retrieval is embeddings plus BM25 plus graph traversal. Zep paper: https://arxiv.org/html/2501.13956v1 [S]. LLM calls per episode come from a docs mirror [S] https://mintlify.com/getzep/graphiti/advanced/performance-tuning.
- **Mem0**: https://docs.mem0.ai/open-source/graph_memory/overview [V]. Their 2026 "92.5 on LoCoMo" claim is vendor-reported [S] https://mem0.ai/blog/state-of-ai-agent-memory-2026.
- **Cognee**: https://github.com/topoteretes/cognee [V]. Default local stack is SQLite (metadata), LanceDB (vectors) and the Kuzu-lineage graph. Ladybug adapter work is in v1.5 notes [S] https://newreleases.io/project/github/topoteretes/cognee/release/v1.5.0, docs https://docs.cognee.ai/guides/ladybug [V].
- **Hindsight**: https://arxiv.org/pdf/2512.12818, https://github.com/vectorize-io/hindsight [V]. Memory is split into world facts, experiences, observations (consolidated beliefs with evidence) and mental models. Good taxonomy for "facts said in meetings" vs "your conclusions".
- **Temporal Semantic Memory (TSM)**: ACL 2026 Findings, arXiv 2601.07468 [S]. It indexes memories by when the event happened (semantic time), not when it was said, and consolidates "durative" memories (ongoing states) from point events. Up to 12.2% absolute gain on LongMemEval/LoCoMo, self-reported. Directly relevant to meetings ("we'll ship next Friday" said on 3 Sep refers to 12 Sep). https://arxiv.org/abs/2601.07468v1
- **Other efficient-indexing papers**: E2GraphRAG (spaCy entity graph, up to 10x faster indexing than GraphRAG) [S] https://arxiv.org/html/2505.24226v2. KET-RAG (KG skeleton from only the most central chunks, about one-tenth the indexing cost) [S] https://pith.science/paper/2502.09304.

### 3.4 Patterns worth stealing (ranked)

1. **Relation-light graph plus PPR** (LinearRAG, HippoRAG 2): entities, chunks and mention edges only. Retrieval is PPR from query-matched entities into chunks. No LLM at index time.
2. **Bi-temporal facts with invalidation and provenance** (Graphiti, ctxgraph).
3. **Budgeted LLM at query time, not index time** (LazyGraphRAG).
4. **Tiered extraction**: deterministic, then small encoder (GLiNER2), then small LLM, escalating only on low confidence (ctxgraph).
5. **Background consolidation** ("sleep-time", Letta; "reflect", Hindsight): merge duplicates, summarize entity pages, and detect superseded decisions when the machine is idle.

---

## 4. Embedded and local graph storage

| Store | Status | iOS | macOS | Bun/Node | Notes |
|---|---|---|---|---|---|
| **SQLite** (FTS5, recursive CTE, JSON) | Rock solid | Yes (system) | Yes (system) | `bun:sqlite` built in | **Recommended.** FTS5 works in `bun:sqlite` on this Mac [M]. 2-hop CTE over 50K/300K edges: 0.16 ms [M] |
| sqlite-vec | Pre-v1 ("expect breaking changes"). Apache-2.0/MIT. Brute force plus IVF/DiskANN work in repo [V]. npm 0.1.9 [M via npm] | Via SQLiteVec / SQLiteVecKit Swift packages [S] | Yes | **Not with Bun's default macOS SQLite**: "This build of sqlite3 does not support dynamic extension loading" [M]. Needs `Database.setCustomSQLite()` pointing to Homebrew SQLite [S] | Skip until you exceed about 500K vectors [E] |
| sqlite-vector (sqliteai) | Apache-2.0, iOS/Android/WASM, "30MB of RAM" default, quantized brute force [V] | Yes | Yes | Same extension-loading caveat | Alternative to sqlite-vec |
| expo-sqlite | `bundledExtensions['sqlite-vec']` plus `loadExtensionAsync`, enabled by `withSQLiteVecExtension` [S, from expo-sqlite 57 type defs] https://cdn.jsdelivr.net/npm/expo-sqlite@57.0.1/build/SQLiteDatabase.d.ts | Yes | | | Bolkit mobile path |
| GraphQLite (colliery-io) | SQLite extension with Cypher (97.7% openCypher TCK). PageRank, Louvain, Dijkstra. 502 stars, MIT [V] | Unclear | Homebrew | Needs extension loading | Interesting, but young |
| sqlite-graph (alpha), SimpleGraph (Swift), simple-graph | Alpha or tiny [S] | | | | Pattern only |
| **Kuzu** | **Archived Oct 10, 2025** (final 0.11.3) [V] https://github.com/kuzudb/kuzu. Apple acquired Kùzu Inc. (agreement Oct 9, 2025, disclosed in EU DMA filing Feb 2026) [S] https://uwaterloo.ca/computer-science/news/waterloo-based-graph-database-start-up-kuzu-acquired-apple, https://heise.de/-11177751. `kuzu-swift` archived [S] | Was yes | | | **Do not start on Kuzu** |
| **LadybugDB** (Kuzu fork) | Very active: last commit Sep 29 2026 [V dbdb.io], npm `@ladybugdb/core` 0.21.1 published 2026-10-01 [M]. MIT. Cypher, FTS and vector index built in. Python/Node/Rust/Go/Swift/Java/WASM [V] | Swift binding exists [V]. iOS demo mentioned [S] | Yes | **Runs under Bun 1.4 on macOS arm64** (verified with a Cypher round-trip). Needs the blocked postinstall trusted or the 21 MB prebuilt `.node` copied in [M] | Best choice if you ever need Cypher or graph analytics. Overkill at personal scale |
| RyuGraph (Kuzu fork) | Releases Oct-Dec 2025, nothing found for 2026 [S] | | | | Watch, don't adopt |
| NeuG (Alibaba GraphScope) | Apr 2026. Embedded plus service modes. Python only, Node on roadmap. Claims 287x vs LadybugDB on triangles [V blog, vendor benchmark] | No | Yes | Not yet | Too new |
| DuckDB + DuckPGQ | Community extension, "research project... some features may still be under development" [V] | No (dynamic extensions) [E] | Yes | Yes (DuckDB node) | Analytics, not app storage |
| FalkorDBLite | Python 3.12+, spawns an embedded Redis server with the FalkorDB module [V] | No | Yes | No | Dev and CI only |
| CozoDB | Last release 0.7.6 Dec 2023, "abandoned" per dbdb.io [S] | | | | **Abandoned** |
| LanceDB | Active (python-v0.34 July 2026). Embedded TS/Python/Rust with vector, FTS and RRF [S] | No Swift SDK found [S] | Yes | Node SDK. Bun untested | Optional vector store, not a graph |
| SurrealDB 3.0 | Swift SDK first alpha 12 Aug 2026, **remote-only**: "embedded... isn't in the alpha" [V] | Not embedded | | | Not yet |
| SwiftData / Core Data | Supports many-to-many relationships. Several sources report slowdowns past about 50K records and recommend GRDB/SQLiteData [S] https://blakecrosley.com/blog/swiftdata-performance-storage-engine | Yes | Yes | | Fine for UI models, not for the graph index |

**Measured micro-benchmarks (this Mac, Bun 1.4.0, random graph, 100 runs)** [M]:
- Recursive CTE neighborhood, 50K nodes and 300K edges, indexed `(src,dst)` and `(dst,src)`, filtered by `valid_to IS NULL`: depth 1 = 0.03 ms, depth 2 = 0.16 ms.
- Flat dot-product scan of 50K x 256-dimension Float32 in plain JS: 9.9 ms per query.
- Personalized PageRank, 20 power iterations over the full 50K/300K graph in JS: 69 ms. Restricting it to the 2-hop subgraph around seeds should bring it under 5 ms [E].

For scale: a heavy user with 1,000 hours of meetings a year produces about 40K chunks a year [E, see section 8]. So SQLite plus brute-force vectors covers years of data.

---

## 5. Cheap extraction without big LLMs

### 5.1 Encoder models (GLiNER family)

- **GLiNER2** (Fastino, EMNLP 2025 demo, arXiv 2507.18546) [V] https://github.com/fastino-ai/GLiNER2
  - NER, classification, structured JSON extraction and relation extraction in one forward pass. Apache-2.0, 2.2K stars.
  - Sizes: GLiNER2 base 205M, large 340M, multilingual about 205M. Newer **GLiNER2.5** boundary models: small 74M, base 194M, multilingual 287M.
  - "CPU first". API: `model.extract_relations(text, ["works_for", ...])`.
- **GLiNER2 Swift (MacPaw, Feb 2026)** [V] https://research.macpaw.com/publications/gliner2-swift, https://github.com/MacPaw/Gliner2Swift
  - Native Swift/MLX. macOS 14+ Apple Silicon. NER, classification and structured extraction work; relations are "in progress".
  - M3 Pro CPU timings: entities 334.8 ms, classification 59.6 ms, structured 288.3 ms, all three 351.9 ms. Bolkit already links MLX.
- A Core AI bundle of a GLiNER2 PII model reportedly runs on iPhone GPU or the Neural Engine [S] https://huggingface.co/coreai-community/GLiNER2-PII-CoreAI.
- **GLiREL** (NAACL 2025) [V abstract]: zero-shot relation classification between entity spans in one pass, DeBERTa-v3-large encoder. https://aclanthology.org/2025.naacl-long.418
- **GLiNER-Relex** (arXiv 2605.10108, May 2026) [V]: joint NER plus relation extraction "in a single call", zero-shot types, CC BY 4.0. The newest option. Model size not stated.
- **JS**: the `gliner` npm package (v1 models only) was last modified Mar 2025 [M via npm], so treat it as stale. In agent-memory, GLiNER would run through `onnxruntime-node` directly [E].

### 5.2 Small LLMs with constrained output

- **Apple Foundation Models** [V] https://developer.apple.com/videos/play/wwdc2026/241/
  - The OS 27 on-device model is "rebuilt from ground up with improved reasoning and tool calling". `contextSize` is 8,192 tokens, with a `tokenCount(for:)` API and vision input.
  - A Private Cloud Compute model has 32K context and reasoning levels, free under 2M first-time downloads.
  - New `LanguageModel` protocol: `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, open-source `CoreAILanguageModel` (Neural Engine) and `MLXLanguageModel`. All share `@Generable` guided generation.
  - On OS 26 the limit is 4,096 tokens, input plus output [S] https://www.natashatherobot.com/p/apple-foundation-models.
  - Apple's 2024 figures for the on-device model: about 0.6 ms per prompt token and 30 tok/s on iPhone 15 Pro [S] https://machinelearning.apple.com/research/introducing-apple-foundation-models.
  - **Core AI** succeeds Core ML for neural nets, with conversion via `TorchConverter().add_exported_program(ep).to_coreai()` [V] https://www.infoq.com/news/2026/06/apple-core-ai-wwdc/.
  - Note from your `Package.swift`: mlx-swift-lm's FoundationModels adapter "targets the 27 beta API and fails on the Xcode 27.0 SDK" [L].
- **Gemma 4** (2 Apr 2026) [S] https://www.llmreference.com/model-family/gemma-4: E2B (2.3B effective) and E4B (4.5B effective), 128K context, function calling, JSON-schema-constrained output. Community speeds for E2B: about 82 tok/s on M3 and 95 tok/s on M4 Pro via Ollama Q4 [S] https://llmcheck.net/models/gemma-4-e2b-on-m4-pro/. Bolkit already runs E2B.
- **Qwen3.5 small** (2 Mar 2026) [S] https://artificialanalysis.ai/articles/qwen3-5-small-models: 0.8B, 2B, 4B and 9B, Apache-2.0, supported in llama.cpp and MLX.
- **llama.cpp grammar**: `llama.rn` exposes `convertJsonSchemaToGrammar` (GBNF) plus embeddings [S] https://www.npmjs.com/package/llama.rn/. The same grammar path is available in Bolkit's linked `CLlama` [E].
- **Android**: ML Kit Prompt API `1.0.0-beta3` with Gemini Nano 4 (Gemma 4 based). Structured output via Kotlin `@Generable` data classes is listed alongside a "GenAI Schema Compiler 1.0.0-alpha1" [V] https://android-developers.googleblog.com/2026/07/android-on-device-inference.html. Device coverage is limited.

### 5.3 Does a tiny model really work for relation extraction?

"Sub-Billion, Super-Frontier" (arXiv 2606.22606) [V abstract]: a **fine-tuned** Qwen2.5-0.5B scored 0.83 micro-F1 against 0.69 for zero-shot GPT-5.4 and 0.66 for Claude Sonnet 4.6. The authors stress the gain "stems from task adaptation", and an in-domain RoBERTa also beat both frontier models. So:
- Zero-shot small LLMs are mediocre at relation extraction. Graphiti warns that small models break JSON schemas [V].
- Constrained decoding fixes format but not judgment.
- **Fine-tuning a sub-1B model, or a GLiNER2 LoRA (supported [V]), on your own corrected extractions is the realistic path to high quality.** Collect those corrections from day one through the UI.

### 5.4 Apple NaturalLanguage framework

`NLTagger` with `.nameType` gives `.personalName`, `.placeName` and `.organizationName` on device with zero download [V] https://developer.apple.com/documentation/naturallanguage/identifying-people-places-and-organizations.md. It's useful as a free first pass and for English. I found no evidence of how it handles romanized Hindi/Hinglish, so treat it as weak there [E].

### 5.5 Entity resolution (where personal graphs usually fail)

Recommended layered approach, synthesized from [S] https://www.mintlify.com/juanceresa/sift-kg/concepts/entity-resolution, https://cocoindex.io/docs/ops/entity_resolution/ and the meeting-KG guide https://www.helix-db.com/content/guides/how-to-build-a-knowledge-graph-from-meeting-notes:
1. **Hard anchors**: diarized speaker identities the user has named (Bolkit already has this), plus contacts and email if available. These are canonical Person nodes.
2. **Deterministic normalization**: case, honorifics (ji, sir, bhai), transliteration variants, plus an alias table per entity.
3. **Blocking**: only compare candidates that share a type plus a token or phonetic key, or sit in the embedding top-k.
4. **Score**: name-embedding similarity plus context similarity (same meetings, same co-mentioned people).
5. **LLM adjudication only for the ambiguous band**, one `@Generable` call returning `{same: Bool, confidence}`.
6. **User confirmation** for merges below high confidence. Never auto-merge two people who appear in the same meeting.

"Less is More: Denoising Knowledge Graphs for RAG" (arXiv 2510.14271) [S] reports that LLM-built KGs carry many duplicate nodes and edges, and that pruning them improves retrieval.

---

## 6. Local embeddings and retrieval

| Model | Size | Notes |
|---|---|---|
| **EmbeddingGemma** (Google, 4 Sep 2025) | 308M | Best open multilingual model under 500M on MTEB at release. 2K context. MRL 768/512/256/128. "less than 200MB of RAM with quantization". <15 ms for 256 tokens on EdgeTPU. 100+ languages. Runs in llama.cpp, MLX, transformers.js, Ollama and LiteRT [V] https://developers.googleblog.com/introducing-embeddinggemma/. ONNX for transformers.js: use fp32/q8/q4, **not fp16** [S] https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX |
| Qwen3-Embedding-0.6B | 0.6B | MMTEB 64.33 mean (task), 32K context, GGUF available [S from paper] https://arxiv.org/html/2506.05176v1 |
| jina-embeddings-v5-text-small / nano | 677M / 239M | Feb 2026. Small model: MTEB-en v2 71.7, MMTEB 67.7, 119+ languages [S] https://jina.ai/news/jina-embeddings-v5-text-distilling-4b-quality-into-sub-1b-multilingual-embeddings. Check license before shipping |
| Granite Embedding R2 | 149M / 47M | English, ModernBERT, Apache-2.0 [S] https://arxiv.org/html/2508.21085v1 |
| BGE-M3 | about 568M | Dense, sparse and multi-vector. LightRAG's local recommendation [V] |
| nomic-embed-text v1.5 | 137M | MTEB-en 62.28 [S] https://www.morphllm.com/ollama-embedding-models |
| Apple NLContextualEmbedding | system | Zero download. 512-dim on iOS, 768-dim on macOS [S] https://swiftpackageregistry.com/buh/NaturalLanguageEmbeddings. Model per language/script group [S]. No public retrieval benchmark found. Fallback only |
| bge-small-en-v1.5 (current agent-memory) | 33M | English only. Fast |

**Rerankers**:
- Qwen3-Reranker-0.6B: MTEB-R 61.82 and MMTEB-R 64.64 [S] https://arxiv.org/html/2506.05176v1.
- bge-reranker-v2-m3: 568M, the most deployed open option [S] https://presenc.ai/research/best-open-weight-reranker-models-2026.
- ms-marco-MiniLM-L-6 (current) is tiny and English-only.
- At personal scale, rerank the top 20-30 only.

**Retrieval recipe (both products)**:
1. Parse filters from the query: person, date range, meeting, "open"/"current".
2. In parallel: FTS5 BM25 over chunks (trigram tokenizer helps with romanized Hindi and ASR misspellings [E]), vector top-k, and entity-name match.
3. Seed PPR from matched entities and top chunks, restricted to a 2-hop subgraph. Pull in chunks connected to those entities across meetings. This is the HippoRAG 2 / LinearRAG step.
4. RRF-fuse, then rerank the top ~25, then apply a recency/validity prior (drop or demote facts with `valid_to` set unless the user asks "what changed").
5. Answer with citations (meeting, speaker, timestamp). For "list" questions such as open action items, skip the LLM and run SQL.

---

## 7. Temporal / personal knowledge graphs for meetings

Proposed minimal schema (SQLite, shared by Bolkit and agent-memory). It merges the HelixDB meeting schema (Meeting, Participant, Utterance, Topic, Decision, ActionItem, Concept; edges ATTENDED, SPOKE, LED_TO, ASSIGNED_TO, IMPLEMENTS, REFERENCES [S]) with Graphiti's bi-temporal facts [V] and TSM's event-time idea [S]:

```sql
CREATE TABLE source (id INTEGER PRIMARY KEY, kind TEXT, title TEXT, started_at TEXT, ended_at TEXT);
CREATE TABLE chunk  (id INTEGER PRIMARY KEY, source_id INT REFERENCES source, speaker_entity INT,
                     start_ms INT, end_ms INT, text TEXT, emb BLOB);
CREATE VIRTUAL TABLE chunk_fts USING fts5(text, content='chunk', content_rowid='id', tokenize='trigram');
CREATE TABLE entity (id INTEGER PRIMARY KEY, type TEXT, name TEXT, aliases TEXT, summary TEXT,
                     emb BLOB, status TEXT, first_seen TEXT, last_seen TEXT);
CREATE TABLE mention(entity_id INT, chunk_id INT, confidence REAL, extractor TEXT);
CREATE TABLE fact   (id INTEGER PRIMARY KEY, src INT, rel TEXT, dst INT, props TEXT,
                     valid_from TEXT, valid_to TEXT, recorded_at TEXT, invalidated_at TEXT,
                     superseded_by INT, chunk_id INT, confidence REAL, extractor TEXT);
CREATE INDEX fact_src ON fact(src, rel) WHERE invalidated_at IS NULL;
CREATE INDEX fact_dst ON fact(dst, rel) WHERE invalidated_at IS NULL;
```

Rules:
- Entity types: Person, Org, Project, Topic, Decision, ActionItem, Concept/Tool. Decisions and action items carry a `status` (open, done, reversed) and link to their chunk through `fact.chunk_id`. That gives an audit trail to the exact timestamp.
- `valid_from` is **event time**: resolve "next Friday" against the meeting date. `recorded_at` is when you learned it.
- Contradiction handling: when a new Decision is extracted, fetch prior open decisions on the same Project or Topic (bounded set, usually under 10). Ask the LLM once, "does the new one supersede any of these?". Set `valid_to` and `superseded_by`; never delete.
- Durative state (TSM): during idle consolidation, roll repeated point facts into one interval fact, for example "Asha owns onboarding redesign, Jun-Sep".
- Chunks remain the ground truth. The graph is an index over text, so a bad extraction degrades ranking but never loses data.

---

## 8. Recommended stack

### 8a. Bolkit on Mac (Swift, fully on-device)

| Layer | Choice | Why |
|---|---|---|
| Storage | **One SQLite file** via the system `SQLite3` module, or GRDB if you want a wrapper. Schema from section 7 | Zero new native deps. FTS5 included. CTE traversal is sub-millisecond at your scale [M] |
| Vectors | `BLOB` column (float16 or int8, 256-d MRL), brute-force with Accelerate `vDSP`/BLAS kept in memory | 50K x 256 is about 25-50 MB in RAM. JS scan is already 10 ms [M], Swift with Accelerate will be faster [E]. Add sqlite-vec or sqlite-vector only past about 500K chunks [E] |
| Embeddings | **EmbeddingGemma-300m** GGUF Q8 via the already-linked llama.cpp (or MLX), truncated to 256-d. Fallback: `NLContextualEmbedding` | Multilingual (Hinglish), <200 MB RAM [V], no new runtime |
| Extraction tier 0 | Diarized, user-named speakers become Person nodes. Meeting metadata | Free and highest precision |
| Extraction tier 1 | **Apple Foundation Models `@Generable`**, one call per meeting over summary plus speaker-attributed key segments: people, projects, topics, decisions, action items (owner, due), relations. On macOS 26 use about 4K of context (chunk it); on 27, 8K [V] | Free, private, system-managed RAM. Bolkit already gates on `SystemLanguageModel.availability` [L] |
| Extraction fallback | Gemma 4 E2B (already loaded) through llama.cpp JSON-schema grammar or MLX | For macOS 14-25 and machines without Apple Intelligence |
| Extraction tier 2 (optional) | GLiNER2 via MacPaw's Swift/MLX port for chunk-level NER and classification | Use only if the eval shows tier 1 misses mentions. About 335 ms per call [V] |
| Entity resolution | Section 5.5 layers. Merge/split UI next to the existing speaker-naming UI | Biggest quality lever |
| Retrieval | Section 6 recipe: FTS5 + vectors + entity PPR (2-hop subgraph) + RRF, then answer with Apple FM or Gemma, citing meeting and timestamp | Graph used only where it helps |
| Background | Run extraction after a meeting is saved, on power, idle QoS. "Sleep-time" consolidation nightly | Keeps recording and dictation latency untouched |

**Cost estimates (M3-class Mac)**. All [E] except where marked. Arithmetic: a 1-hour meeting is about 9,000 words, about 12K tokens, about 54 KB text, and about 40 chunks of 300 tokens.

| Item | Estimate |
|---|---|
| Disk per meeting-hour | Text 54 KB, FTS5 index about 50 KB, vectors 40 x 256 x 2 B = 20 KB, graph rows about 10 KB. **About 140 KB, so about 150 MB per 1,000 meeting-hours** |
| Extra RAM while indexing | EmbeddingGemma <200 MB [V]. GLiNER2 base about 410 MB fp16 weights (205M x 2 B) if enabled. Apple FM is OS-managed. Gemma 4 E2B already resident in Bolkit (no new cost, not re-measured) |
| Extra RAM at query time | Vector matrix 25-50 MB per 50K chunks, plus the embedder |
| Background indexing per meeting-hour | Embeddings: 40 chunks at about 10-30 ms each, about 1 s. Apple FM extraction: about 2K tokens in, 600 out, 10-25 s. GLiNER2 tier: 40 x 0.35 s = 14 s [V per-call figure]. **Total about 15-40 s, off the hot path** |
| Query latency | Embed query 10-30 ms. FTS5 plus vector scan plus CTE under 15 ms [M components]. Rerank 25 docs 0.2-0.8 s if enabled [S]. Answer generation 2-8 s. **Retrieval-only "list" queries (open action items) under 50 ms** |

### 8b. agent-memory (Bun/TypeScript)

| Layer | Choice | Why |
|---|---|---|
| Storage | **Migrate the JSON stores to one `bun:sqlite` file per project.** Section 7 schema with `source` = session/transcript/note | Removes the 44 MB `index.json` rewrites and the cache/flush race in `LEARNINGS.md` [L]. FTS5 confirmed in `bun:sqlite` [M]. No new dependency |
| Lexical | FTS5 `bm25()` replaces the hand-rolled inverted index and TF-IDF | Less code |
| Vectors | Keep the flat scan (`vectors.bin`, or move to a BLOB column). **Don't add sqlite-vec**: extension loading is blocked on Bun's macOS SQLite [M] and needs Homebrew `setCustomSQLite` [S] | Flat scan is 10 ms at 50K x 256 [M] |
| Embeddings | Run `eval/eval-set.json` on bge-small-en-v1.5 (current) vs **EmbeddingGemma q8 via transformers.js at 256-d MRL**. Switch only if it wins | Multilingual and better retrieval quality are expected but unmeasured on your data |
| Extraction | (1) **Host-agent extraction for free**: extend `memory_store` with optional `facts: [{subject, predicate, object, valid_from}]` and `supersedes`, filled by the calling coding agent, which is already a frontier LLM. (2) Deterministic extractors for transcripts: file paths, symbols joined to `code-graph.ts`, packages, ticket IDs (`[A-Z]+-\d+`), env vars, URLs, commands. (3) Optional idle "distill" pass (`distill.ts` exists [L]) | Zero local LLM cost. Most agent-memory entities are code artifacts with exact names |
| Temporal | Add `valid_from`, `valid_to`, `invalidated_at`, `superseded_by` and `chunk_id` to edges. Decisions and gotchas get `status`. Default queries hide invalidated facts | Fixes stale decisions resurfacing in `memory_context` |
| Retrieval | Keep BM25 + embedding RRF + MiniLM rerank. **Add PPR seeded from matched entities**, reusing the PageRank code in `repo-map.ts` [L], limited to a 2-hop subgraph | HippoRAG 2-style multi-hop at about 1K tokens per query [V] |
| Not adopting | Graphiti, Cognee, LightRAG, Hindsight (Python or Postgres, LLM-heavy writes). LadybugDB works under Bun [M] but adds a 21 MB native addon plus a postinstall trust step. Revisit only if you need Cypher or graph algorithms beyond PPR | Ladder: SQLite already does it |

**Cost estimates** [E]:
- Disk should drop from today's 1.8 GB, since pretty-printed JSON indexes are replaced by FTS5 (re-measure after migration).
- Write path: one SQLite transaction per `memory_store`, under 5 ms excluding embedding. Embedding about 10-40 ms per chunk on CPU.
- Query: under 30 ms before rerank, about 100-300 ms with the MiniLM rerank of 20.
- RAM: the vector matrix for the largest project (604 MB store today) is the main cost. Measure it before and after.

### 8c. Phones (later)

- Same SQLite schema.
- iOS and Android in the Expo app: `expo-sqlite` with bundled sqlite-vec [S], plus `llama.rn` for EmbeddingGemma GGUF embeddings and JSON-schema-constrained extraction with Gemma 4 E2B or Qwen3.5-0.8B/2B [S].
- Native iOS gets Apple FM `@Generable` through an Expo module.
- Android gets the ML Kit Prompt API (beta) with Gemini Nano 4 where the device supports it [V].
- Simplest viable plan: phones capture, Mac indexes, phones query a synced copy. Sync design is out of scope here.

---

## 9. Phased build plan

| Phase | Scope | Exit criterion |
|---|---|---|
| 0. Eval (2-3 days) | Bolkit: 40-60 real questions over your own meetings, split into fact lookup, cross-meeting, action items, "what changed". agent-memory: extend `eval/eval-set.json` the same way | A runnable script reporting hit@5 and answer accuracy per category |
| 1. SQLite + hybrid search (1-2 weeks) | Both products: section 7 tables (chunks, FTS5, vectors), speaker and time filters. Bolkit: import existing `meeting.json` files and `UserDefaults` history. agent-memory: migrate JSON stores | Matches or beats today on the eval. **No graph yet** |
| 2. Entities and mentions (1-2 weeks) | Speakers as Person anchors, cheap NER, alias table, merge/split UI, entity pages ("everything about Asha") | Under 5% duplicate people on a manual audit of 100 entities |
| 3. Typed facts (2 weeks) | Bolkit: one Apple FM `@Generable` call per meeting for decisions, action items and relations, with Gemma fallback. agent-memory: `facts` field on `memory_store` plus deterministic extractors. Bi-temporal edges and supersession | Action-item and decision precision of at least 80% on 20 audited meetings |
| 4. Graph retrieval (1 week) | PPR-seeded retrieval, query routing (graph only for cross-meeting and "what changed" intents, per "Use Graph When It Needs"), timeline view | Measurable gain on cross-meeting and "what changed" categories with no regression on fact lookup. **If no gain, stop here and ship phases 1-3** |
| 5. Consolidation and learning (ongoing) | Nightly "sleep-time" pass: dedupe, durative facts, entity summaries. Log user corrections as training data and optionally fine-tune GLiNER2 LoRA or a sub-1B model on them | Correction rate trends down |
| 6. Mobile | Section 8c | Same eval on device within an agreed latency budget |

---

## 10. The 3 most important risks

1. **The graph may not beat good hybrid search for most of your questions.** GraphRAG-Bench shows vanilla RAG plus rerank winning on fact retrieval [V], and LoCoMo-style memory benchmarks are saturated by full context [V Hindsight blog]. *Mitigation:* phases 0-1 ship value without a graph. Phase 4 has an explicit stop rule. Route queries so the graph runs only for intents where it measurably helps.
2. **Extraction and entity-resolution quality on Hinglish ASR output with small on-device models.** ASR misspells names. NLTagger and the English GLiNER models are English-centric [E]. Small models break JSON schemas [V Graphiti] and are weak zero-shot at relation extraction [V 2606.22606]. Wrong merges and wrong "superseded" links produce confidently wrong answers. *Mitigation:* anchor on user-named speakers. Keep chunks as ground truth with provenance on every fact. Never auto-merge below a high threshold. Use constrained decoding (`@Generable` or GBNF). Treat user corrections as training data. Check which languages Apple FM supports for your users before relying on it, since I didn't verify Hindi support.
3. **Ecosystem churn under you.** In the last year Kuzu was archived after the Apple acquisition [V], Mem0 OSS dropped graph memory [V], Zep CE was deprecated [S], MS GraphRAG went into maintenance mode [V], the Apple FM context window and APIs changed between OS 26 and 27 [V], your mlx-swift-lm FoundationModels adapter already breaks on Xcode 27.0 [L], and sqlite-vec is pre-v1 [V]. *Mitigation:* own a plain SQLite schema and use the frameworks only as reference designs. Keep model backends behind the `LanguageModel` protocol (Swift) or a one-function interface (TS). Avoid GPL code (LinearRAG) in Bolkit.

---

## Appendix: what was checked locally

- Code reads: `localvoice/mac/Package.swift`, `Sources/Scribe/{MeetingDetailView,DictationManager,MeetingPipeline,LLMEngine,MLXRuntime}.swift`, `localvoice/package.json`, `agent-memory/{package.json,README.md,LEARNINGS.md,src/types.ts,src/graph.ts,src/vector-store.ts,src/storage.ts}`.
- Benchmarks: scratch scripts `bench.ts` and `ppr.ts` in this scratchpad directory, run with Bun 1.4.0 on an M3 Pro with 18 GB.
- LadybugDB under Bun: `@ladybugdb/core` 0.21.1 installed in scratchpad `lbtest/`. Bun blocked the postinstall, and copying the prebuilt `lbugjs.node` from `@ladybugdb/core-darwin-arm64` was enough. A Cypher CREATE/MATCH round-trip with a DATE property worked.
- npm metadata (via `npm view`): `@ladybugdb/core` 0.21.1 (2026-10-01), `lbug` 0.14.3 (2026-01-30, older package name), `sqlite-vec` 0.1.9, `gliner` 0.0.19 (2025-03-02), `@huggingface/transformers` 4.3.0.
