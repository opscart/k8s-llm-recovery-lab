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
loader rejects unknown or missing fields, files larger than 32 KiB, more than 20
summarized events, oversized fields, and high-confidence credential patterns.
Raw container logs are intentionally absent from the contract.

## Incident contracts

Version 1 remains loadable as legacy observation evidence, but it has no source
identity and therefore cannot authorize an LLM call. This prevents a
semantically similar manifest from being treated as the affected workload's
configuration.

Version 2 is required for repository-grounded incident generation. Use
`rag/fixtures/incidents/checkout-api-probe-failure.json` as the reviewed example.
Required top-level fields are:

- `schema_version` (must be `2` for generation)
- cluster, observation time, namespace, and focus pod
- workload kind and name
- source repository and exact repository-relative path
- classification and severity
- container name, state, and restart count
- bounded summary and event summaries

Source identity is a provenance assertion, not a similarity hint. Only retrieved
chunks whose repository and path exactly match the declared source are sent to
the LLM and accepted as citation authority. A missing identity or a retrieval
miss produces `Insufficient evidence`; `--allow-low-confidence` cannot bypass
this gate.

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

The checked-in probe fixture should report `source_identity=verified` and
retrieve the OpsCart failure-lab manifest at
`examples/failure-lab/manifests/probe-failure.yaml`. Do not lower the
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
