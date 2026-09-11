# Local-First RAG Foundation

## Purpose

This phase builds and evaluates repository retrieval before the paid GPU VM is started. It runs embeddings and retrieval on the workstation CPU and only calls vLLM after the retrieval gate passes.

```text
Clean local Git repositories
  -> tracked-file and secret filters
  -> line-preserving chunks
  -> pinned CPU embedding model
  -> dense vectors + SQLite FTS5
  -> hybrid retrieval
  -> exact repo/path/line/commit citations
  -> optional Qwen/vLLM answer
```

RAG is read-only. This implementation does not clone repositories, use GitHub credentials, write code, open pull requests, access pipelines, or contact Kubernetes.

## Pinned inputs

| Dependency | Pin |
| --- | --- |
| PyTorch | `2.14.0` (CPU wheel) |
| Sentence Transformers | `6.0.1` |
| NumPy | `2.2.6` |
| SOCKS proxy support | `socksio 1.0.0` |
| Embedding model | `BAAI/bge-small-en-v1.5` |
| Embedding revision | `5c38ec7c405ec4b44b94cc5a9bb96e735b38267a` |

The embedding model is small enough for local CPU indexing. It is downloaded
only when the index is first built; retrieval and evaluation then load the
pinned revision from the local cache. The Qwen model and GPU are not used when
building or evaluating the index.

## Safety boundaries

The indexer:

- reads only files returned by `git ls-files`
- refuses repositories with modified tracked files
- records the exact repository commit
- excludes generated/vendor directories and large or binary files
- excludes common credential and private-key paths
- skips a whole file when a high-confidence secret pattern is detected
- preserves exact source line ranges and content hashes
- refuses to overwrite an existing index

These controls reduce accidental exposure but are not a substitute for a dedicated secret scanner. Run the organization's approved scanner before indexing production repositories.

Local repository paths are stored only in the ignored `repos.local.json`. Absolute paths are not written to the portable index manifest.

## 1. Install the local environment

No Azure VM is required:

```bash
scripts/rag/setup-rag-env.sh
```

The setup supports Python 3.10 through 3.13, explicitly installs the CPU-only
PyTorch wheel, and verifies that SQLite FTS5 is available. On Linux it fails if
the resulting PyTorch build reports a CUDA runtime.

## 2. Configure one pilot repository

```bash
cp rag/config/repos.example.json rag/config/repos.local.json
```

Review the file. Repository paths are resolved relative to this repository's root. The initial example indexes only `k8s-llm-recovery-lab`.

Do not add all 20 repositories yet. After the first evaluation passes, add one representative application repository as the second pilot.

## 3. Build the index on CPU

Ensure every configured repository has a clean tracked working tree, then run:

```bash
scripts/rag/index-repositories.sh
```

The default output is:

```text
artifacts/rag/index/
  manifest.json
  chunks.sqlite3
  embeddings.npy
```

The index and embedding-model cache are ignored by Git. To rebuild, preserve the old index and specify a new path instead of deleting evidence in place:

```bash
RAG_INDEX_DIR=artifacts/rag/index-02 \
  scripts/rag/index-repositories.sh
```

## 4. Inspect retrieval without an LLM

```bash
scripts/rag/query-repositories.sh \
  --retrieve-only \
  --question "Which pinned CNI is configured for the GPU node?"
```

The output contains ranked citations, line ranges, scores, hashes, and bounded content previews. This step requires no GPU and makes retrieval mistakes visible before generation can hide them.

## 5. Run the retrieval evaluation

```bash
scripts/rag/evaluate-retrieval.sh
```

The example evaluation contains five labeled questions for this repository. The default gate requires at least 80% hit rate at six retrieved chunks and writes:

```text
results/rag/retrieval-evaluation.json
```

Expand the evaluation set before adding more repositories. Each JSONL record contains an ID, a question, and one or more acceptable source paths.

## 6. Ask Qwen only after retrieval passes

During the later controlled GPU session, deploy vLLM and establish a localhost tunnel:

```bash
kubectl port-forward \
  service/vllm-qwen25-coder \
  18000:8000 \
  -n llm-recovery-lab \
  --address 127.0.0.1
```

In a second terminal:

```bash
scripts/rag/query-repositories.sh \
  --question "How does this repository prevent an unpinned CNI manifest?"
```

The query layer treats retrieved source as untrusted data, limits context to fit the 8K model window, requires citations from the retrieved set, and accepts an uncited response only when it explicitly reports insufficient evidence.

Raw queries, retrieved context, requests, responses, and answers are written beneath `results/rag/queries/` and ignored by Git by default.

## Promotion gate

Do not add GitHub, pipeline, or AKS credentials after one successful demonstration. Promotion requires:

1. a two-repository pilot
2. a labeled retrieval set covering both repositories
3. acceptable citation validity and retrieval hit rate
4. explicit no-answer tests
5. prompt-injection tests using hostile text inside an indexed repository
6. review of CPU latency, index size, and Qwen response quality

Only then should a separate read-only connector phase begin.
