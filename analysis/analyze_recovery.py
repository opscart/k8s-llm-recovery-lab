#!/usr/bin/env python3

from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]

DATASETS = {
    "llama3.2-1b": ROOT / "results/local-mac/ollama/llama3.2-1b/pvc-recovery.csv",
    "llama3.2-3b": ROOT / "results/local-mac/ollama/llama3.2-3b/pvc-recovery-4gi.csv",
}

OUT = ROOT / "analysis/local-mac-recovery-summary.csv"


def summarize(name: str, path: Path) -> dict:
    df = pd.read_csv(path)

    required = [
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

    missing = [col for col in required if col not in df.columns]
    if missing:
        raise ValueError(
            f"{name}: missing required columns: {', '.join(missing)}"
        )

    result = {
        "model": name,
        "runs": len(df),
    }

    for col in required:
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


def main():
    summaries = []

    for name, path in DATASETS.items():
        if not path.exists():
            raise FileNotFoundError(f"Dataset not found: {path}")

        summaries.append(summarize(name, path))

    summary_df = pd.DataFrame(summaries)
    summary_df.to_csv(OUT, index=False)

    print()
    print("Local Mac Recovery Summary")
    print("=" * 78)

    display_cols = [
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
            display[col] = display[col].map(lambda x: round(seconds(x), 3))

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

    if len(summary_df) == 2:
        one = summary_df[summary_df["model"] == "llama3.2-1b"].iloc[0]
        three = summary_df[summary_df["model"] == "llama3.2-3b"].iloc[0]

        print()
        print("1B -> 3B Change")
        print("=" * 78)

        comparison_metrics = {
            "Kubernetes Ready": "pod_recovery_ms_mean",
            "Runtime Reachable": "runtime_recovery_ms_mean",
            "Functional Recovery": "functional_recovery_ms_mean",
            "Ready -> Inference": "ready_to_inference_ms_mean",
            "Model Load": "load_duration_ms_mean",
            "Ollama Total": "total_duration_ms_mean",
        }

        for label, col in comparison_metrics.items():
            old = one[col]
            new = three[col]

            pct = ((new - old) / old) * 100 if old != 0 else float("nan")

            print(
                f"{label:24} "
                f"{seconds(old):8.3f}s -> "
                f"{seconds(new):8.3f}s "
                f"({pct:+7.2f}%)"
            )

        if (
            "memory_current_bytes_mean" in summary_df.columns
            and pd.notna(three.get("memory_current_bytes_mean"))
        ):
            gib = three["memory_current_bytes_mean"] / (1024 ** 3)
            print()
            print(f"3B mean post-inference memory: {gib:.3f} GiB")

    print()
    print(f"Full statistical summary written to:")
    print(OUT)


if __name__ == "__main__":
    main()