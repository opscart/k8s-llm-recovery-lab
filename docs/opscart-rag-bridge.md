# OpsCart incident-to-RAG bridge

This bridge combines a bounded live OpsCart observation with repository evidence.
It does not scrape the dashboard, contact Kubernetes, modify workloads, or grant
the model credentials.

## Trust boundary

- OpsCart incident JSON says what is happening now.
- RAG retrieval finds the versioned source that may explain it.
- Qwen generates a diagnosis from both inputs.
- Repository citations remain mandatory for configuration and remediation claims.
- The bridge is advisory only. It cannot apply YAML, rerun a pipeline, or merge code.

Live incident fields and repository chunks are placed in separate untrusted-data
markers. Marker-like text inside either input is escaped before prompting. The
version-1 loader rejects unknown or missing fields, files larger than 32 KiB,
more than 20 summarized events, oversized fields, and high-confidence credential
patterns. Raw container logs are intentionally absent from the contract.

## Version-1 incident contract

Use `rag/fixtures/incidents/checkout-api-probe-failure.json` as the reviewed
example. Required top-level fields are:

- `schema_version` (must be `1`)
- cluster, observation time, namespace, and focus pod
- workload kind and name
- classification and severity
- container name, state, and restart count
- bounded summary and event summaries

The fixture is manually transcribed lab evidence, not a live OpsCart API export.
A production integration should add a versioned, authenticated JSON endpoint to
OpsCart rather than parse HTML.

## Offline retrieval test

Keep the GPU VM deallocated while checking that the incident identity retrieves
the relevant source:

```bash
RAG_INDEX_DIR=artifacts/rag/index-two-repo \
  scripts/rag/diagnose-opscart-incident.sh \
  rag/fixtures/incidents/checkout-api-probe-failure.json \
  --retrieve-only
```

The checked-in probe fixture should retrieve the OpsCart failure-lab manifest,
including `examples/failure-lab/manifests/probe-failure.yaml`. Do not lower the
answerability threshold merely to force an answer.

## Controlled generation test

Start the paid VM only after retrieval passes and the SSH port-forward exposes
vLLM at `127.0.0.1:18000`:

```bash
RAG_INDEX_DIR=artifacts/rag/index-two-repo \
  scripts/rag/diagnose-opscart-incident.sh \
  rag/fixtures/incidents/checkout-api-probe-failure.json
```

The evidence directory contains the original generation question, the separate
retrieval question, normalized incident JSON, retrieved chunks, request, response,
decision, raw answer, and validated answer. Review the proposed change manually;
do not grant the LLM write access.

## Index freshness

The bridge diagnoses against the commit SHAs recorded in the RAG index. Rebuild to
a new index directory after relevant repository changes, evaluate it, and only then
switch consumers to it. Existing indexes are preserved for reproducibility.
