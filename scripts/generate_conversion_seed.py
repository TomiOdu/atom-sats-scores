"""Generate seeds/seed_sats_conversion.csv and seeds/seed_sats_paper.csv.

WHY THIS SCRIPT EXISTS
----------------------
The 2026 KS2 conversion tables are published by the Standards and Testing Agency as
a web page, not a downloadable dataset. The anchor points recorded during that
research are in docs/ai/03_scoring_research.md; this script rebuilds the full
mark-by-mark curve from them so the seed is reproducible rather than hand-typed.

IMPORTANT - PROVENANCE
----------------------
The ANCHORS below are transcribed from the published tables. The marks BETWEEN
anchors are monotone linear interpolation, not published values. They are accurate
to roughly a scaled point in the middle of the range and exact at every anchor, but
they are a reconstruction.

This is disclosed in README section 7 and docs/SCORING.md section 3. Replacing the
anchors with a full transcription of the GOV.UK page would make the seed exact; the
check_documented_figures() assertions at the bottom keep working either way - they
verify the seed against every figure quoted in docs/SCORING.md and
docs/ai/03_scoring_research.md.

Run:  python scripts/generate_conversion_seed.py
"""

from __future__ import annotations

import csv
import math
from pathlib import Path

CONVERSION_YEAR = 2026
SEED_DIR = Path(__file__).resolve().parent.parent / "seeds"

# Per-paper metadata, taken directly from the published tables.
PAPERS = {
    # paper:    (max_raw_mark, min_raw_mark_for_score, raw_for_100, raw_for_110)
    "reading": (50, 3, 25, 39),
    "gps": (70, 3, 34, 55),
    "maths": (110, 3, 56, 94),
}

# Anchor points as (percentage_of_max_marks, scaled_score), from
# docs/ai/03_scoring_research.md. Converted to raw marks below using the same
# rounding rule the SQL applies, so the seed and the model agree by construction.
PCT_ANCHORS = {
    "reading": [
        (20, 89), (30, 93), (40, 97), (45, 98), (50, 100), (55, 102), (58, 103),
        (60, 103), (65, 105), (70, 107), (75, 109), (80, 111), (85, 113),
        (90, 117), (95, 120),
    ],
    "gps": [
        (20, 90), (30, 94), (40, 97), (45, 99), (50, 100), (55, 101), (58, 103),
        (60, 103), (65, 105), (70, 107), (75, 108), (80, 111), (85, 114),
        (90, 117), (95, 120),
    ],
    "maths": [
        (20, 90), (30, 94), (40, 97), (45, 98), (50, 99), (55, 101), (58, 101),
        (60, 102), (65, 103), (70, 105), (75, 106), (80, 108), (85, 110),
        (90, 112), (95, 115),
    ],
}

SCALED_MIN, SCALED_MAX = 80, 120


def sql_round(value: float) -> int:
    """Round half away from zero, matching BigQuery ROUND(). Python's built-in
    round() is banker's rounding and would disagree at exact halves."""
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


def build_anchors(paper: str) -> list[tuple[int, int]]:
    """Raw-mark anchors for a paper: the percentage anchors converted to marks,
    plus the published 100 and 110 thresholds and the two endpoints."""
    max_raw, min_raw, raw_100, raw_110 = PAPERS[paper]

    anchors: dict[int, int] = {}
    for pct, scaled in PCT_ANCHORS[paper]:
        anchors[sql_round(pct * max_raw / 100)] = scaled

    # Published thresholds win over anything interpolation implies.
    anchors[raw_100] = 100
    anchors[raw_110] = 110
    # The lowest mark that earns a score earns the lowest score; the top of the
    # paper earns the top of the scale.
    anchors[min_raw] = SCALED_MIN
    anchors[max_raw] = SCALED_MAX

    ordered = sorted(anchors.items())
    scores = [s for _, s in ordered]
    if scores != sorted(scores):
        raise ValueError(f"{paper}: anchors are not monotonic: {ordered}")
    return ordered


def build_curve(paper: str) -> list[tuple[int, int | None]]:
    """One (raw_mark, scaled_score) pair for every mark from 0 to the paper max.
    NULL below the minimum mark that earns a score."""
    max_raw, min_raw, _, _ = PAPERS[paper]
    anchors = build_anchors(paper)

    rows: list[tuple[int, int | None]] = []
    for raw in range(0, max_raw + 1):
        if raw < min_raw:
            rows.append((raw, None))
            continue

        # Find the bracketing anchors and interpolate between them.
        lower = max((a for a in anchors if a[0] <= raw), key=lambda a: a[0])
        upper_candidates = [a for a in anchors if a[0] >= raw]
        upper = min(upper_candidates, key=lambda a: a[0]) if upper_candidates else lower

        if upper[0] == lower[0]:
            scaled = lower[1]
        else:
            span = upper[0] - lower[0]
            scaled = sql_round(lower[1] + (upper[1] - lower[1]) * (raw - lower[0]) / span)

        rows.append((raw, max(SCALED_MIN, min(SCALED_MAX, scaled))))
    return rows


def write_conversion_seed(curves: dict[str, list[tuple[int, int | None]]]) -> int:
    path = SEED_DIR / "seed_sats_conversion.csv"
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow(["conversion_year", "paper", "raw_mark", "scaled_score"])
        count = 0
        for paper in ("reading", "gps", "maths"):
            for raw, scaled in curves[paper]:
                writer.writerow([CONVERSION_YEAR, paper, raw, "" if scaled is None else scaled])
                count += 1
    print(f"wrote {path.name}: {count} rows")
    return count


def write_paper_seed() -> None:
    path = SEED_DIR / "seed_sats_paper.csv"
    labels = {
        "reading": "English reading",
        "gps": "English grammar, punctuation and spelling",
        "maths": "Mathematics",
    }
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh, lineterminator="\n")
        writer.writerow([
            "conversion_year", "paper", "paper_label", "max_raw_mark",
            "min_raw_mark_for_score", "expected_standard_raw_mark",
            "higher_standard_raw_mark",
        ])
        for paper, (max_raw, min_raw, raw_100, raw_110) in PAPERS.items():
            writer.writerow([
                CONVERSION_YEAR, paper, labels[paper], max_raw, min_raw, raw_100, raw_110,
            ])
    print(f"wrote {path.name}: {len(PAPERS)} rows")


def check_documented_figures(curves: dict[str, list[tuple[int, int | None]]]) -> None:
    """Every figure quoted in docs/SCORING.md and docs/ai/03_scoring_research.md, checked
    against the generated seed. If a figure here fails, either the seed is wrong or
    the documentation is - do not silently change one to match the other."""
    lookup = {
        paper: {raw: scaled for raw, scaled in rows} for paper, rows in curves.items()
    }

    # SCORING.md section 3 / 03_scoring_research.md - published thresholds.
    for paper, (max_raw, min_raw, raw_100, raw_110) in PAPERS.items():
        assert lookup[paper][raw_100] == 100, f"{paper}: {raw_100} marks should give 100"
        assert lookup[paper][raw_110] == 110, f"{paper}: {raw_110} marks should give 110"
        assert lookup[paper][min_raw - 1] is None, f"{paper}: below {min_raw} marks scores nothing"
        assert lookup[paper][min_raw] == 80, f"{paper}: {min_raw} marks should give 80"
        assert lookup[paper][max_raw] == 120, f"{paper}: full marks should give 120"

    # 03_scoring_research.md - the percentage-to-scaled-score table.
    for paper, anchors in PCT_ANCHORS.items():
        max_raw = PAPERS[paper][0]
        for pct, expected in anchors:
            raw = sql_round(pct * max_raw / 100)
            actual = lookup[paper][raw]
            assert actual == expected, (
                f"{paper} at {pct}% (raw {raw}): documented {expected}, generated {actual}"
            )

    # docs/SCORING.md section 3 - the "what typical percentages produce" table.
    # Checked here so the document cannot drift from the seed it describes. The
    # 66% row is the one that caught a real error: an earlier draft had reading
    # at 106, but 65% and 66% of 50 marks both round to 33, so they cannot differ.
    scoring_doc_summary = {
        # pct: (reading, gps, maths)
        30: (93, 94, 94),
        40: (97, 97, 97),
        50: (100, 100, 99),
        58: (103, 103, 101),
        66: (105, 105, 103),
        75: (109, 108, 106),
        85: (113, 114, 110),
        95: (120, 120, 115),
    }
    for pct, expected_row in scoring_doc_summary.items():
        for paper, expected in zip(("reading", "gps", "maths"), expected_row):
            raw = sql_round(pct * PAPERS[paper][0] / 100)
            actual = lookup[paper][raw]
            assert actual == expected, (
                f"SCORING.md 3: {paper} at {pct}% (raw {raw}): "
                f"documented {expected}, generated {actual}"
            )

    # Monotonicity - a pupil who scores an extra mark can never score lower.
    for paper, rows in curves.items():
        scored = [s for _, s in rows if s is not None]
        assert scored == sorted(scored), f"{paper}: curve is not monotonic"
        assert min(scored) >= SCALED_MIN and max(scored) <= SCALED_MAX, f"{paper}: out of range"

    print("all documented figures reproduced")


if __name__ == "__main__":
    curves = {paper: build_curve(paper) for paper in PAPERS}
    check_documented_figures(curves)
    total = write_conversion_seed(curves)
    write_paper_seed()
    print(f"total conversion rows: {total}")
