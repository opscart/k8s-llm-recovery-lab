#!/usr/bin/env python3
"""
Analyze the frozen CPU/GPU Ollama recovery datasets.

Run:
    python3 analysis/analyze_gpu_recovery.py

Outputs:
    analysis/gpu-recovery-summary.csv
    analysis/cpu-gpu-recovery-summary.csv

Uses only the Python standard library.
"""

from __future__ import annotations

import csv
import statistics
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Experiment:
    key: str
    label: str
    platform: str
    model: str
    condition: str
    resource_envelope: str
    relative_path: str


EXPERIMENTS = (
    Experiment(
        "azure_cpu_llama32_3b",
        "Azure CPU Llama 3.2 3B",
        "Azure CPU",
        "llama3.2:3b",
        "PVC baseline",
        "2 CPU / 4 GiB limit",
        "results/cloud-cpu/ollama/llama3.2-3b/pvc-recovery-4gi.csv",
    ),
    Experiment(
        "gpu_llama32_3b_ephemeral_cuda_cache",
        "T4 Llama 3.2 3B - ephemeral CUDA ComputeCache",
        "Azure T4 GPU",
        "llama3.2:3b",
        "ephemeral CUDA ComputeCache",
        "2 CPU / 4 GiB limit / 1 GPU",
        "results/cloud-gpu/ollama/llama3.2-3b/recovery/gpu-recovery.csv",
    ),
    Experiment(
        "gpu_llama32_3b_persistent_cuda_cache",
        "T4 Llama 3.2 3B - persistent CUDA ComputeCache",
        "Azure T4 GPU",
        "llama3.2:3b",
        "persistent CUDA ComputeCache",
        "2 CPU / 4 GiB limit / 1 GPU",
        "results/cloud-gpu/ollama/llama3.2-3b/recovery/gpu-recovery-persistent-cuda-cache.csv",
    ),
    Experiment(
        "gpu_llama31_8b_persistent_cuda_cache",
        "T4 Llama 3.1 8B - persistent CUDA ComputeCache",
        "Azure T4 GPU",
        "llama3.1:8b",
        "persistent CUDA ComputeCache",
        "2 CPU / 4 GiB limit / 1 GPU",
        "results/cloud-gpu/ollama/llama3.1-8b/recovery/gpu-recovery-persistent-cuda-cache.csv",
    ),
    Experiment(
        "gpu_qwen3_14b_20gi_persistent_cuda_cache",
        "T4 Qwen3 14B - 20 GiB persistent CUDA ComputeCache",
        "Azure T4 GPU",
        "qwen3:14b",
        "persistent CUDA ComputeCache; mmap-enabled right-sized run",
        "2 CPU / 20 GiB limit / 1 GPU",
        "results/cloud-gpu/ollama/qwen3-14b/recovery/gpu-recovery-20gi-persistent-cuda-cache.csv",
    ),
)

METRICS = {
    "pod_recovery_ms": ("kubernetes_ready_s", "s", 1000.0),
    "runtime_recovery_ms": ("runtime_reachable_s", "s", 1000.0),
    "ready_to_runtime_ms": ("ready_to_runtime_s", "s", 1000.0),
    "functional_recovery_ms": ("functional_recovery_s", "s", 1000.0),
    "ready_to_inference_ms": ("ready_to_inference_s", "s", 1000.0),
    "request_wall_ms": ("request_wall_s", "s", 1000.0),
    "total_duration_ms": ("ollama_total_s", "s", 1000.0),
    "load_duration_ms": ("model_load_s", "s", 1000.0),
    "prompt_eval_duration_ms": ("prompt_eval_s", "s", 1000.0),
    "eval_duration_ms": ("eval_s", "s", 1000.0),
    "memory_current_bytes": ("memory_current_gib", "GiB", 1024.0**3),
    "gpu_used_mib_before": ("gpu_used_before_mib", "MiB", 1.0),
    "gpu_used_mib_after": ("gpu_used_after_mib", "MiB", 1.0),
}

CORE_MEANS = (
    "kubernetes_ready_s",
    "runtime_reachable_s",
    "functional_recovery_s",
    "ready_to_inference_s",
    "request_wall_s",
    "model_load_s",
    "ollama_total_s",
    "prompt_eval_s",
    "eval_s",
    "memory_current_gib",
    "gpu_used_before_mib",
    "gpu_used_after_mib",
)


def repo_root() -> Path:
    root = Path(__file__).resolve().parent.parent
    if not (root / "results").is_dir():
        raise RuntimeError(f"results/ not found under repository root: {root}")
    return root


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        raise FileNotFoundError(path)
    with path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        raise ValueError(f"No data rows in {path}")
    return rows


def values(rows: list[dict[str, str]], column: str, divisor: float) -> list[float]:
    out = []
    for row in rows:
        raw = row.get(column)
        if raw is None or raw.strip() == "":
            continue
        out.append(float(raw) / divisor)
    return out


def describe(xs: list[float]) -> dict[str, float | int]:
    return {
        "n": len(xs),
        "mean": statistics.fmean(xs),
        "median": statistics.median(xs),
        "stddev": statistics.stdev(xs) if len(xs) > 1 else 0.0,
        "min": min(xs),
        "max": max(xs),
    }


def http_success(rows: list[dict[str, str]]) -> tuple[int, int]:
    if "http_code" not in rows[0]:
        return 0, 0
    codes = [r["http_code"].strip() for r in rows if r.get("http_code", "").strip()]
    return sum(code == "200" for code in codes), len(codes)


def fmt(value):
    if isinstance(value, float):
        return f"{value:.6f}"
    return value


def write_csv(path: Path, rows: list[dict[str, object]], fields: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: fmt(row.get(field, "")) for field in fields})


def main() -> int:
    root = repo_root()
    long_rows = []
    cross_rows = []

    for exp in EXPERIMENTS:
        rows = read_csv(root / exp.relative_path)
        ok, checked = http_success(rows)

        cross = {
            "experiment": exp.key,
            "label": exp.label,
            "platform": exp.platform,
            "model": exp.model,
            "condition": exp.condition,
            "resource_envelope": exp.resource_envelope,
            "source_file": exp.relative_path,
            "runs": len(rows),
            "http_200_runs": ok if checked else "",
            "http_checked_runs": checked if checked else "",
        }

        for source, (metric, unit, divisor) in METRICS.items():
            xs = values(rows, source, divisor)
            if not xs:
                continue

            stats = describe(xs)
            long_rows.append(
                {
                    "experiment": exp.key,
                    "label": exp.label,
                    "platform": exp.platform,
                    "model": exp.model,
                    "condition": exp.condition,
                    "resource_envelope": exp.resource_envelope,
                    "source_file": exp.relative_path,
                    "metric": metric,
                    "unit": unit,
                    **stats,
                }
            )
            if metric in CORE_MEANS:
                cross[f"mean_{metric}"] = stats["mean"]

        cross_rows.append(cross)

    analysis = root / "analysis"
    long_path = analysis / "gpu-recovery-summary.csv"
    cross_path = analysis / "cpu-gpu-recovery-summary.csv"

    long_fields = [
        "experiment", "label", "platform", "model", "condition",
        "resource_envelope", "source_file", "metric", "unit",
        "n", "mean", "median", "stddev", "min", "max",
    ]
    cross_fields = [
        "experiment", "label", "platform", "model", "condition",
        "resource_envelope", "source_file", "runs",
        "http_200_runs", "http_checked_runs",
        *[f"mean_{m}" for m in CORE_MEANS],
    ]

    write_csv(long_path, long_rows, long_fields)
    write_csv(cross_path, cross_rows, cross_fields)

    print(
        f"{'Experiment':49} {'n':>3} {'K8s':>8} "
        f"{'Ready->Inf':>10} {'Functional':>10} {'Load':>8} {'Total':>8}"
    )
    print("-" * 101)

    for row in cross_rows:
        def g(name):
            value = row.get(name, "")
            return "-" if value == "" else f"{float(value):.3f}"

        print(
            f"{str(row['label'])[:49]:49} {int(row['runs']):>3} "
            f"{g('mean_kubernetes_ready_s'):>8} "
            f"{g('mean_ready_to_inference_s'):>10} "
            f"{g('mean_functional_recovery_s'):>10} "
            f"{g('mean_model_load_s'):>8} "
            f"{g('mean_ollama_total_s'):>8}"
        )

    print("\nTimes above are seconds.")
    print(f"Generated: {long_path.relative_to(root)}")
    print(f"Generated: {cross_path.relative_to(root)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)

