#!/usr/bin/env python3

from pathlib import Path
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]

RAW = (
    ROOT
    / "results"
    / "local-mac"
    / "ollama"
    / "llama3.2-3b"
    / "readiness"
    / "ollama-3b-inference-readiness-endpoints.csv"
)

OUT = ROOT / "analysis" / "local-mac-readiness-summary.csv"


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
    old_removed_detected = first_sample_after(sample_times, old_last_seen)

    nonserving_ms = (
        new_ready - new_first_seen
        if new_ready is not None and new_first_seen is not None
        else None
    )

    traffic_gap_samples = 0
    both_ready_samples = 0

    for _, sample in run_df.groupby("timestamp_ms"):
        eligible = sample[sample["ready"] & sample["serving"]]
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


def main():
    if not RAW.exists():
        raise FileNotFoundError(f"Raw readiness CSV not found: {RAW}")

    df = pd.read_csv(RAW)

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
            "Raw readiness CSV is missing required columns: "
            + ", ".join(missing)
        )

    # timestamp_ms is authoritative. The first automated run contains a
    # malformed human-readable timestamp on macOS, so timestamp_utc is
    # intentionally not used for calculations.
    df["timestamp_ms"] = pd.to_numeric(df["timestamp_ms"], errors="raise")
    df["ready"] = as_bool(df["ready"])
    df["serving"] = as_bool(df["serving"])
    df["terminating"] = as_bool(df["terminating"])

    summaries = [
        summarize_run(run_df)
        for _, run_df in df.groupby("run", sort=True)
    ]

    summary = pd.DataFrame(summaries)
    summary.to_csv(OUT, index=False)

    print()
    print("Local Mac 3B Inference-Aware Readiness Summary")
    print("=" * 88)

    display = summary[
        [
            "run",
            "new_endpoint_nonserving_ms",
            "traffic_gap_samples",
            "both_ready_samples",
        ]
    ].copy()

    display["new_endpoint_nonserving_s"] = (
        display["new_endpoint_nonserving_ms"] / 1000.0
    ).round(3)

    display = display[
        [
            "run",
            "new_endpoint_nonserving_s",
            "traffic_gap_samples",
            "both_ready_samples",
        ]
    ]

    print(display.to_string(index=False))

    valid = summary["new_endpoint_nonserving_ms"].dropna()

    print()
    print("Aggregate")
    print("=" * 88)

    if not valid.empty:
        print(f"Runs analyzed                  : {len(summary)}")
        print(f"Mean non-serving duration      : {valid.mean()/1000:.3f} s")
        print(f"Median non-serving duration    : {valid.median()/1000:.3f} s")
        print(f"Stddev non-serving duration    : {valid.std(ddof=1)/1000:.3f} s")
        print(f"Minimum non-serving duration   : {valid.min()/1000:.3f} s")
        print(f"Maximum non-serving duration   : {valid.max()/1000:.3f} s")
    else:
        print("No valid new-endpoint readiness transitions were found.")

    total_gap_samples = int(summary["traffic_gap_samples"].sum())
    runs_with_gap = int((summary["traffic_gap_samples"] > 0).sum())

    print(f"Total traffic-gap samples      : {total_gap_samples}")
    print(f"Runs containing traffic gap    : {runs_with_gap}/{len(summary)}")

    print()
    if total_gap_samples == 0:
        print(
            "Observed result: every sampled interval contained at least one "
            "EndpointSlice endpoint with ready=true and serving=true."
        )
    else:
        print(
            "Observed result: at least one sampled interval had no ready+serving "
            "EndpointSlice endpoint. Inspect the affected run(s) before drawing "
            "availability conclusions."
        )

    print()
    print("Corrected derived summary written to:")
    print(OUT)


if __name__ == "__main__":
    main()
