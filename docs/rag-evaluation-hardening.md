# RAG Evaluation Hardening

## Purpose

This phase tests whether retrieval remains useful when more than one repository
is indexed. It runs entirely on the workstation CPU. It does not start Azure,
call Qwen, clone repositories, or use repository credentials.

The supplied pilot uses these local sibling repositories:

- `k8s-llm-recovery-lab`
- `opscart-k8s-watcher`

The repository list is an example. Review every path before building an index.
Only clean, Git-tracked files pass through the foundation's ingestion filters.

## What changed

The evaluation format now labels every answerable question with both an exact
repository and one or more exact source paths. This prevents a same-named file
in the wrong repository from counting as a hit.

The report includes:

- overall hit rate at K
- per-repository hit rate
- mean reciprocal rank
- cross-repository top-result error rate
- negative-question pass rate
- the answerability score used for each question
- explicit gate failures and the thresholds that produced them

Retrieval-only queries print a compact six-line citation summary by default.
Use `--output-format json` only when the complete machine-readable result is
needed.

## Answerability boundary

The pilot uses a dense-similarity threshold of `0.68`. Below that value, the
query command returns `Insufficient evidence` without calling the LLM. The
threshold separated the supplied positive and negative questions in the
two-repository pilot; it is a calibrated starting point, not a universal truth.

Recalibrate it when the repository mix or embedding model changes. Never lower
the threshold merely to make a failing evaluation green. Inspect false
positives and false negatives first.

## Prompt-injection boundary

Retrieved text remains untrusted data in the user message. The system message
instructs the model not to obey role changes, secret requests, tool commands,
or policy overrides contained inside source chunks. Unit tests verify that
hostile source text cannot enter the system message and that invented
citations are rejected.

These are structural controls. They do not prove that a model will resist every
prompt-injection attempt. Behavioral attacks must still be included in the
later, time-boxed Qwen session.

## Prepare the two-repository configuration

Both repositories should be siblings under the same parent directory. From
`k8s-llm-recovery-lab`:

```bash
cp \
  rag/config/repos.two-repo.example.json \
  rag/config/repos.two-repo.local.json

git status --short
git -C ../opscart-k8s-watcher status --short
```

Both status commands must show no tracked modifications. The local config is
ignored by Git.

## Build a separate immutable index

Do not overwrite the original one-repository evidence:

```bash
RAG_REPOS_CONFIG=rag/config/repos.two-repo.local.json \
RAG_INDEX_DIR=artifacts/rag/index-two-repo \
  scripts/rag/index-repositories.sh
```

The embedding model is already cached from the foundation test. This command
reads and embeds the additional repository on CPU; it does not download Qwen
or use Azure.

## Run the hardened gate

```bash
scripts/rag/evaluate-two-repo-pilot.sh
```

The example contains 20 positive questions split evenly across the two
repositories and four negative questions. The gate requires:

| Metric | Threshold |
| --- | ---: |
| Overall hit rate at 6 | at least `0.85` |
| Per-repository hit rate at 6 | at least `0.80` |
| Positive answerability rate | `1.00` |
| Negative-question pass rate | `1.00` |
| Cross-repository top-1 error rate | at most `0.20` |

The detailed report is written to
`results/rag/two-repo-evaluation.json`. RAG result files are ignored by Git so
a local test does not dirty the working tree.

## Inspect individual retrievals

Relevant question:

```bash
RAG_INDEX_DIR=artifacts/rag/index-two-repo \
  scripts/rag/query-repositories.sh \
  --retrieve-only \
  --question "Which unhealthy node conditions are critical and which are high severity?"
```

Negative question:

```bash
RAG_INDEX_DIR=artifacts/rag/index-two-repo \
  scripts/rag/query-repositories.sh \
  --retrieve-only \
  --question "What is the employee international travel meal reimbursement limit?"
```

The first should report `answerable=yes`; the second should report
`answerable=no`. Neither command calls Qwen.

## Exit criteria

Do not start the GPU VM until:

1. the hardened gate passes against the exact two local repository commits
2. failed and borderline questions have been manually reviewed
3. the answerability threshold is accepted for the pilot scope
4. the GPU-session runbook and immediate-deallocation sequence are reviewed

Passing this gate validates retrieval only. It does not authorize pull-request
merges, pipeline reruns, or Kubernetes changes.
