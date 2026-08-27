#!/usr/bin/env python3

from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]

DATASETS = {
    "local-1b": {
        "platform": "local-mac",
        "model": "llama3.2-1b",
        "path": ROOT / "results/local-mac/ollama/llama3.2-1b/pvc-recovery.csv",
    },
    "local-3b": {
        "platform": "local-mac",
        "model": "llama3.2-3b",
        "path": ROOT / "results/local-mac/ollama/llama3.2-3b/pvc-recovery-4gi.csv",
    },
    "azure-1b": {
        "platform": "azure-cpu",
        "model": "llama3.2-1b",
        "path": ROOT / "results/cloud-cpu/ollama/llama3.2-1b/pvc-recovery.csv",
    },
    "azure-3b": {
        "platform": "azure-cpu",
        "model": "llama3.2-3b",
        "path": ROOT / "results/cloud-cpu/ollama/llama3.2-3b/pvc-recovery-4gi.csv",
    },
}

OUT = ROOT / "analysis/recovery-cross-platform-summary.csv"

REQUIRED = [
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


def summarize(name, config):
    path = config["path"]

    if not path.exists():
        raise FileNotFoundError(f"{name}: dataset not found: {path}")

    df = pd.read_csv(path)

    missing = [col for col in REQUIRED if col not in df.columns]
    if missing:
        raise ValueError(
            f"{name}: missing required columns: {', '.join(missing)}"
        )

    if "http_code" in df.columns:
        bad = df[df["http_code"].astype(str) != "200"]
        if not bad.empty:
            raise ValueError(
                f"{name}: contains {len(bad)} failed inference run(s)"
            )

    result = {
        "dataset": name,
        "platform": config["platform"],
        "model": config["model"],
        "runs": len(df),
    }

    for col in REQUIRED:
        result[f"{col}_mean"] = df[col].mean()
        result[f"{col}_median"] = df[col].median()
        result[f"{col}_stddev"] = df[col].std(ddof=1)
        result[f"{col}_min"] = df[col].min()
        result[f"{col}_max"] = df[col].max()

    if "memory_current_bytes" in df.columns:
        result["memory_current_bytes_mean"] = df["memory_current_bytes"].mean()
        result["memory_current_bytes_median"] = df["memory_current_bytes"].median()
        result["memory_current_bytes_min"] = df["memory_current_bytes"].min()
        result["memory_current_bytes_max"] = df["memory_current_bytes"].max()

    return result


def seconds(ms):
    return ms / 1000.0


def pct_change(old, new):
    if old == 0:
        return float("nan")
    return ((new - old) / old) * 100.0


def print_comparison(title, old_row, new_row):
    print()
    print(title)
    print("=" * 86)

    metrics = {
        "Kubernetes Ready": "pod_recovery_ms_mean",
        "Runtime Reachable": "runtime_recovery_ms_mean",
        "Ready -> Runtime": "ready_to_runtime_ms_mean",
        "Functional Recovery": "functional_recovery_ms_mean",
        "Ready -> Inference": "ready_to_inference_ms_mean",
        "Request Wall": "request_wall_ms_mean",
        "Model Load": "load_duration_ms_mean",
        "Prompt Evaluation": "prompt_eval_duration_ms_mean",
        "Token Evaluation": "eval_duration_ms_mean",
        "Ollama Total": "total_duration_ms_mean",
    }

    for label, col in metrics.items():
        old = old_row[col]
        new = new_row[col]
        pct = pct_change(old, new)

        print(
            f"{label:24} "
            f"{seconds(old):8.3f}s -> "
            f"{seconds(new):8.3f}s "
            f"({pct:+7.2f}%)"
        )


def main():
    summaries = []

    for name, config in DATASETS.items():
        summaries.append(summarize(name, config))

    summary_df = pd.DataFrame(summaries)
    summary_df.to_csv(OUT, index=False)

    print()
    print("Cross-Platform Recovery Summary")
    print("=" * 86)

    display_cols = [
        "dataset",
        "platform",
        "model",
        "runs",
        "pod_recovery_ms_mean",
        "runtime_recovery_ms_mean",
        "functional_recovery_ms_mean",
        "ready_to_inference_ms_mean",
        "load_duration_ms_mean",
        "total_duration_ms_mean",
    ]

    display = summary_df[display_cols].copy()

    for col in display.columns:
        if col.endswith("_ms_mean"):
            display[col] = display[col].map(
                lambda x: round(seconds(x), 3)
            )

    display = display.rename(
        columns={
            "pod_recovery_ms_mean": "k8s_ready_s",
            "runtime_recovery_ms_mean": "runtime_s",
            "functional_recovery_ms_mean": "functional_s",
            "ready_to_inference_ms_mean": "ready_to_inference_s",
            "load_duration_ms_mean": "model_load_s",
            "total_duration_ms_mean": "ollama_total_s",
        }
    )

    print(display.to_string(index=False))

    rows = {
        row["dataset"]: row
        for _, row in summary_df.iterrows()
    }

    print_comparison(
        "Local Mac: 1B -> 3B",
        rows["local-1b"],
        rows["local-3b"],
    )

    print_comparison(
        "Azure CPU: 1B -> 3B",
        rows["azure-1b"],
        rows["azure-3b"],
    )

    print_comparison(
        "1B Platform Change: Local Mac -> Azure CPU",
        rows["local-1b"],
        rows["azure-1b"],
    )

    print_comparison(
        "3B Platform Change: Local Mac -> Azure CPU",
        rows["local-3b"],
        rows["azure-3b"],
    )

    for dataset in ["local-3b", "azure-3b"]:
        row = rows[dataset]

        if (
            "memory_current_bytes_mean" in summary_df.columns
            and pd.notna(row.get("memory_current_bytes_mean"))
        ):
            gib = row["memory_current_bytes_mean"] / (1024 ** 3)
            print()
            print(
                f"{dataset} mean post-inference memory: "
                f"{gib:.3f} GiB"
            )

    print()
    print("Full statistical summary written to:")
    print(OUT)


if __name__ == "__main__":
    main()
