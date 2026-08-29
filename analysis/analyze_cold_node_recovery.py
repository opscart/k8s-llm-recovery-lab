#!/usr/bin/env python3

from pathlib import Path
import csv
import statistics

ROOT = Path(__file__).resolve().parents[1]

CONTROL_CSV = ROOT / (
    "results/cloud-cpu/ollama/llama3.2-3b/cold-node/"
    "same-topology-cold-control.csv"
)

CROSS_NODE_CSV = ROOT / (
    "results/cloud-cpu/ollama/llama3.2-3b/cold-node/"
    "node-b-recovery.csv"
)

SUMMARY_CSV = ROOT / "analysis/cold-node-recovery-summary.csv"

METRICS = [
    "pod_recovery_ms",
    "runtime_recovery_ms",
    "ready_to_runtime_ms",
    "functional_recovery_ms",
    "ready_to_inference_ms",
    "request_wall_ms",
    "total_duration_ms",
    "load_duration_ms",
    "prompt_eval_duration_ms",
    "eval_duration_ms",
]


def read_rows(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def stats(rows, metric):
    values = [float(row[metric]) for row in rows]

    return {
        "n": len(values),
        "mean_ms": statistics.mean(values),
        "median_ms": statistics.median(values),
        "stddev_ms": statistics.stdev(values) if len(values) > 1 else 0.0,
        "min_ms": min(values),
        "max_ms": max(values),
    }


control = read_rows(CONTROL_CSV)
cross_node = read_rows(CROSS_NODE_CSV)

if len(control) != 10:
    raise SystemExit(
        f"Expected 10 same-topology control runs, found {len(control)}"
    )

if len(cross_node) != 1:
    raise SystemExit(
        f"Expected exactly 1 preserved cross-node first-use run, found {len(cross_node)}"
    )

summary_rows = []

print("Cold-node recovery analysis")
print()
print(f"Same-topology cold control runs : {len(control)}")
print(f"Cross-node first-use runs       : {len(cross_node)}")
print()

for metric in METRICS:
    s = stats(control, metric)
    cross = float(cross_node[0][metric])

    delta_ms = cross - s["mean_ms"]
    delta_pct = (delta_ms / s["mean_ms"]) * 100.0

    summary_rows.append({
        "metric": metric,
        "control_n": s["n"],
        "control_mean_ms": round(s["mean_ms"], 3),
        "control_median_ms": round(s["median_ms"], 3),
        "control_stddev_ms": round(s["stddev_ms"], 3),
        "control_min_ms": round(s["min_ms"], 3),
        "control_max_ms": round(s["max_ms"], 3),
        "cross_node_first_use_ms": round(cross, 3),
        "cross_node_minus_control_mean_ms": round(delta_ms, 3),
        "cross_node_vs_control_mean_pct": round(delta_pct, 3),
    })

    print(
        f"{metric:28s} "
        f"control_mean={s['mean_ms']:8.1f} ms  "
        f"cross_node={cross:8.1f} ms  "
        f"delta={delta_pct:+6.2f}%"
    )

SUMMARY_CSV.parent.mkdir(parents=True, exist_ok=True)

with SUMMARY_CSV.open("w", newline="") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=summary_rows[0].keys(),
    )
    writer.writeheader()
    writer.writerows(summary_rows)

print()
print(f"Wrote: {SUMMARY_CSV.relative_to(ROOT)}")
