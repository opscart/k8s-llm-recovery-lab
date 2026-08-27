#!/usr/bin/env python3

from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]

DATASETS = {
    "warm": {
        "cache_condition": "warm",
        "platform": "azure-cpu",
        "model": "llama3.2-3b",
        "path": ROOT / (
            "results/cloud-cpu/ollama/llama3.2-3b/cache/"
            "warm-cache-recovery.csv"
        ),
    },
    "cold": {
        "cache_condition": "cold",
        "platform": "azure-cpu",
        "model": "llama3.2-3b",
        "path": ROOT / (
            "results/cloud-cpu/ollama/llama3.2-3b/cache/"
            "cold-cache-recovery.csv"
        ),
    },
}

OUT = ROOT / "analysis/cache-recovery-summary.csv"

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

CACHE_COLUMNS = {
    "warm": {
        "before": "cached_kb_before",
        "after": "cached_kb_after_precondition",
    },
    "cold": {
        "before": "cached_kb_before",
        "after": "cached_kb_after_drop",
    },
}


def pct_change(old, new):
    if old == 0:
        return float("nan")
    return ((new - old) / old) * 100.0


def seconds(ms):
    return ms / 1000.0


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

    if len(df) != 10:
        raise ValueError(
            f"{name}: expected 10 runs, found {len(df)}"
        )

    if "cache_condition" not in df.columns:
        raise ValueError(f"{name}: missing cache_condition column")

    expected_condition = config["cache_condition"]
    bad_condition = df[df["cache_condition"] != expected_condition]
    if not bad_condition.empty:
        raise ValueError(
            f"{name}: contains rows with unexpected cache condition"
        )

    if "http_code" in df.columns:
        bad_http = df[df["http_code"].astype(str) != "200"]
        if not bad_http.empty:
            raise ValueError(
                f"{name}: contains {len(bad_http)} failed inference run(s)"
            )

    if "precondition_model_resident" not in df.columns:
        raise ValueError(
            f"{name}: missing precondition_model_resident column"
        )

    residency = (
        df["precondition_model_resident"]
        .astype(str)
        .str.lower()
    )

    if name == "warm":
        bad_residency = residency != "true"
    else:
        bad_residency = residency != "false"

    if bad_residency.any():
        raise ValueError(
            f"{name}: residency precondition failed in "
            f"{int(bad_residency.sum())} run(s)"
        )

    if name == "cold":
        if "drop_caches_success" not in df.columns:
            raise ValueError(
                "cold: missing drop_caches_success column"
            )

        drop_ok = (
            df["drop_caches_success"]
            .astype(str)
            .str.lower()
            == "true"
        )

        if not drop_ok.all():
            raise ValueError(
                "cold: drop_caches failed in "
                f"{int((~drop_ok).sum())} run(s)"
            )

    result = {
        "dataset": name,
        "platform": config["platform"],
        "model": config["model"],
        "cache_condition": config["cache_condition"],
        "runs": len(df),
    }

    for col in REQUIRED:
        result[f"{col}_mean"] = df[col].mean()
        result[f"{col}_median"] = df[col].median()
        result[f"{col}_stddev"] = df[col].std(ddof=1)
        result[f"{col}_min"] = df[col].min()
        result[f"{col}_max"] = df[col].max()

    if "memory_current_bytes" in df.columns:
        result["memory_current_bytes_mean"] = (
            df["memory_current_bytes"].mean()
        )
        result["memory_current_bytes_median"] = (
            df["memory_current_bytes"].median()
        )
        result["memory_current_bytes_min"] = (
            df["memory_current_bytes"].min()
        )
        result["memory_current_bytes_max"] = (
            df["memory_current_bytes"].max()
        )

    cache_cols = CACHE_COLUMNS[name]
    before_col = cache_cols["before"]
    after_col = cache_cols["after"]

    if before_col not in df.columns or after_col not in df.columns:
        raise ValueError(
            f"{name}: missing cache-state evidence columns"
        )

    result["cached_kb_before_mean"] = df[before_col].mean()
    result["cached_kb_after_mean"] = df[after_col].mean()
    result["cached_kb_delta_mean"] = (
        df[after_col] - df[before_col]
    ).mean()
    result["cached_kb_delta_median"] = (
        df[after_col] - df[before_col]
    ).median()

    if name == "cold":
        if not (df[after_col] < df[before_col]).all():
            raise ValueError(
                "cold: cache did not decrease in every run"
            )

        reduction_pct = (
            (df[before_col] - df[after_col])
            / df[before_col]
            * 100.0
        )

        result["cache_reduction_pct_mean"] = reduction_pct.mean()
        result["cache_reduction_pct_median"] = reduction_pct.median()
        result["cache_reduction_pct_min"] = reduction_pct.min()
        result["cache_reduction_pct_max"] = reduction_pct.max()

    return result


def print_comparison(warm_row, cold_row):
    print()
    print("Azure 3B Cache Condition Comparison: Warm -> Cold")
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
        warm = warm_row[col]
        cold = cold_row[col]
        pct = pct_change(warm, cold)

        print(
            f"{label:24} "
            f"{seconds(warm):8.3f}s -> "
            f"{seconds(cold):8.3f}s "
            f"({pct:+7.2f}%)"
        )


def main():
    summaries = []

    for name, config in DATASETS.items():
        summaries.append(summarize(name, config))

    summary_df = pd.DataFrame(summaries)
    summary_df.to_csv(OUT, index=False)

    print()
    print("Azure 3B Cache Recovery Summary")
    print("=" * 86)

    display_cols = [
        "dataset",
        "cache_condition",
        "runs",
        "pod_recovery_ms_mean",
        "runtime_recovery_ms_mean",
        "functional_recovery_ms_mean",
        "ready_to_inference_ms_mean",
        "request_wall_ms_mean",
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
            "request_wall_ms_mean": "request_wall_s",
            "load_duration_ms_mean": "model_load_s",
            "total_duration_ms_mean": "ollama_total_s",
        }
    )

    print(display.to_string(index=False))

    rows = {
        row["dataset"]: row
        for _, row in summary_df.iterrows()
    }

    print_comparison(rows["warm"], rows["cold"])

    print()
    print("Cache treatment evidence")
    print("=" * 86)

    warm = rows["warm"]
    cold = rows["cold"]

    print(
        "Warm mean Cached before       : "
        f"{warm['cached_kb_before_mean']:.0f} kB"
    )
    print(
        "Warm mean Cached after        : "
        f"{warm['cached_kb_after_mean']:.0f} kB"
    )
    print(
        "Cold mean Cached before       : "
        f"{cold['cached_kb_before_mean']:.0f} kB"
    )
    print(
        "Cold mean Cached after drop   : "
        f"{cold['cached_kb_after_mean']:.0f} kB"
    )
    print(
        "Cold mean cache reduction     : "
        f"{cold['cache_reduction_pct_mean']:.2f}%"
    )

    if "memory_current_bytes_mean" in summary_df.columns:
        warm_gib = (
            warm["memory_current_bytes_mean"] / (1024 ** 3)
        )
        cold_gib = (
            cold["memory_current_bytes_mean"] / (1024 ** 3)
        )

        print()
        print(
            "Post-inference memory is reported descriptively only:"
        )
        print(f"  warm mean: {warm_gib:.3f} GiB")
        print(f"  cold mean: {cold_gib:.3f} GiB")
        print(
            "  no causal interpretation is assigned to this "
            "difference by this analysis"
        )

    print()
    print("Full statistical summary written to:")
    print(OUT)


if __name__ == "__main__":
    main()
