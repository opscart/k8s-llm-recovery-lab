#!/usr/bin/env python3

from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]

DATASETS = {
    "local-3b": {
        "platform": "local-mac",
        "model": "llama3.2-3b",
        "path": (
            ROOT
            / "results/local-mac/ollama/llama3.2-3b/readiness"
            / "ollama-3b-inference-readiness-endpoints.csv"
        ),
    },
    "azure-3b": {
        "platform": "azure-cpu",
        "model": "llama3.2-3b",
        "path": (
            ROOT
            / "results/cloud-cpu/ollama/llama3.2-3b/readiness"
            / "inference-readiness-endpoints.csv"
        ),
    },
}

OUT = ROOT / "analysis/readiness-cross-platform-summary.csv"


def as_bool(series: pd.Series) -> pd.Series:
    return (
        series.astype(str)
        .str.strip()
        .str.lower()
        .map({"true": True, "false": False})
        .fillna(False)
    )


def first_ts(df: pd.DataFrame, mask: pd.Series):
    values = df.loc[mask, "timestamp_ms"]
    return int(values.min()) if not values.empty else None


def first_sample_after(sample_times, ts):
    if ts is None:
        return None

    later = [int(x) for x in sample_times if int(x) > int(ts)]
    return min(later) if later else None


def summarize_run(run_df: pd.DataFrame) -> dict:
    run_df = run_df.sort_values("timestamp_ms").copy()

    run = int(run_df["run"].iloc[0])

    run_start = int(run_df["timestamp_ms"].min())
    run_end = int(run_df["timestamp_ms"].max())

    old_rows = run_df[run_df["role"] == "old"]
    new_rows = run_df[run_df["role"] == "new"]

    old_ip = old_rows["ip"].iloc[0] if not old_rows.empty else ""
    new_ip = new_rows["ip"].iloc[0] if not new_rows.empty else ""

    new_first_seen = (
        int(new_rows["timestamp_ms"].min())
        if not new_rows.empty
        else None
    )

    new_ready = first_ts(
        run_df,
        (run_df["role"] == "new")
        & run_df["ready"]
        & run_df["serving"],
    )

    old_not_ready = first_ts(
        run_df,
        (run_df["role"] == "old")
        & ((~run_df["ready"]) | (~run_df["serving"])),
    )

    old_last_seen = (
        int(old_rows["timestamp_ms"].max())
        if not old_rows.empty
        else None
    )

    sample_times = sorted(run_df["timestamp_ms"].unique())

    old_removed_detected = first_sample_after(
        sample_times,
        old_last_seen,
    )

    nonserving_ms = (
        new_ready - new_first_seen
        if new_ready is not None and new_first_seen is not None
        else None
    )

    traffic_gap_samples = 0
    both_ready_samples = 0

    for _, sample in run_df.groupby("timestamp_ms"):
        eligible = sample[
            sample["ready"] & sample["serving"]
        ]

        if eligible.empty:
            traffic_gap_samples += 1

        old_eligible = (
            (sample["role"] == "old")
            & sample["ready"]
            & sample["serving"]
        ).any()

        new_eligible = (
            (sample["role"] == "new")
            & sample["ready"]
            & sample["serving"]
        ).any()

        if old_eligible and new_eligible:
            both_ready_samples += 1

    return {
        "run": run,
        "run_start_ms": run_start,
        "run_end_ms": run_end,
        "run_observation_ms": run_end - run_start,
        "old_ip": old_ip,
        "new_ip": new_ip,
        "new_endpoint_first_seen_ms": new_first_seen,
        "new_endpoint_ready_ms": new_ready,
        "old_endpoint_not_ready_ms": old_not_ready,
        "old_endpoint_last_seen_ms": old_last_seen,
        "old_endpoint_removed_detected_ms": old_removed_detected,
        "new_endpoint_nonserving_ms": nonserving_ms,
        "traffic_gap_samples": traffic_gap_samples,
        "both_ready_samples": both_ready_samples,
    }


def analyze_dataset(name, config):
    path = config["path"]

    if not path.exists():
        raise FileNotFoundError(
            f"{name}: readiness CSV not found: {path}"
        )

    df = pd.read_csv(path)

    required = {
        "run",
        "timestamp_ms",
        "ip",
        "role",
        "ready",
        "serving",
        "terminating",
    }

    missing = sorted(required - set(df.columns))
    if missing:
        raise ValueError(
            f"{name}: missing required columns: "
            + ", ".join(missing)
        )

    # timestamp_ms is authoritative.
    # timestamp_utc is intentionally excluded from calculations.
    df["timestamp_ms"] = pd.to_numeric(
        df["timestamp_ms"],
        errors="raise",
    )

    df["ready"] = as_bool(df["ready"])
    df["serving"] = as_bool(df["serving"])
    df["terminating"] = as_bool(df["terminating"])

    run_summaries = pd.DataFrame(
        [
            summarize_run(run_df)
            for _, run_df in df.groupby("run", sort=True)
        ]
    )

    valid = run_summaries[
        "new_endpoint_nonserving_ms"
    ].dropna()

    result = {
        "dataset": name,
        "platform": config["platform"],
        "model": config["model"],
        "runs": len(run_summaries),
        "nonserving_mean_ms": valid.mean(),
        "nonserving_median_ms": valid.median(),
        "nonserving_stddev_ms": valid.std(ddof=1),
        "nonserving_min_ms": valid.min(),
        "nonserving_max_ms": valid.max(),
        "traffic_gap_samples": int(
            run_summaries["traffic_gap_samples"].sum()
        ),
        "runs_with_traffic_gap": int(
            (
                run_summaries["traffic_gap_samples"] > 0
            ).sum()
        ),
        "both_ready_samples": int(
            run_summaries["both_ready_samples"].sum()
        ),
    }

    return result, run_summaries


def seconds(ms):
    return ms / 1000.0


def pct_change(old, new):
    if old == 0:
        return float("nan")

    return ((new - old) / old) * 100.0


def main():
    aggregate_rows = []
    per_run = {}

    for name, config in DATASETS.items():
        aggregate, run_summary = analyze_dataset(
            name,
            config,
        )

        aggregate_rows.append(aggregate)
        per_run[name] = run_summary

    summary = pd.DataFrame(aggregate_rows)
    summary.to_csv(OUT, index=False)

    print()
    print("Cross-Platform 3B Inference-Aware Readiness Summary")
    print("=" * 92)

    display = summary[
        [
            "dataset",
            "platform",
            "runs",
            "nonserving_mean_ms",
            "nonserving_median_ms",
            "nonserving_min_ms",
            "nonserving_max_ms",
            "traffic_gap_samples",
            "runs_with_traffic_gap",
        ]
    ].copy()

    for col in [
        "nonserving_mean_ms",
        "nonserving_median_ms",
        "nonserving_min_ms",
        "nonserving_max_ms",
    ]:
        display[col] = (
            display[col] / 1000.0
        ).round(3)

    display = display.rename(
        columns={
            "nonserving_mean_ms": "mean_nonserving_s",
            "nonserving_median_ms": "median_nonserving_s",
            "nonserving_min_ms": "min_nonserving_s",
            "nonserving_max_ms": "max_nonserving_s",
        }
    )

    print(display.to_string(index=False))

    rows = {
        row["dataset"]: row
        for _, row in summary.iterrows()
    }

    local = rows["local-3b"]
    azure = rows["azure-3b"]

    print()
    print("Platform Change: Local Mac -> Azure CPU")
    print("=" * 92)

    metrics = {
        "Mean non-serving": "nonserving_mean_ms",
        "Median non-serving": "nonserving_median_ms",
        "Minimum non-serving": "nonserving_min_ms",
        "Maximum non-serving": "nonserving_max_ms",
    }

    for label, col in metrics.items():
        old = local[col]
        new = azure[col]

        print(
            f"{label:24} "
            f"{seconds(old):8.3f}s -> "
            f"{seconds(new):8.3f}s "
            f"({pct_change(old, new):+7.2f}%)"
        )

    print()
    print(
        "Local traffic-gap samples  : "
        f"{int(local['traffic_gap_samples'])}"
    )
    print(
        "Azure traffic-gap samples  : "
        f"{int(azure['traffic_gap_samples'])}"
    )

    print(
        "Local runs with gap        : "
        f"{int(local['runs_with_traffic_gap'])}/"
        f"{int(local['runs'])}"
    )

    print(
        "Azure runs with gap        : "
        f"{int(azure['runs_with_traffic_gap'])}/"
        f"{int(azure['runs'])}"
    )

    print()
    if (
        local["traffic_gap_samples"] == 0
        and azure["traffic_gap_samples"] == 0
    ):
        print(
            "Observed result: both environments maintained "
            "at least one ready+serving EndpointSlice endpoint "
            "during every sampled interval."
        )
    else:
        print(
            "Observed result: at least one environment contained "
            "a sampled Service traffic gap. Inspect per-run evidence."
        )

    print()
    print("Full statistical summary written to:")
    print(OUT)


if __name__ == "__main__":
    main()
