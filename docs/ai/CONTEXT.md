# Context handover

Everything needed to continue this work without the preceding conversation. Read
this first if you are picking the project up in a new session.

This file is rewritten at each handover rather than appended to, so it always
describes the project as it stands now. How it got here is in
`01_planning_and_prompts.md` (design and profiling) and `04_implementation_session.md`
(the build).

Last updated: 24/09/2026, after the build in Atom's dataset.

---

## 1. The task

Atom Learning Data Engineer take-home (`take-home-task-data-engineer.pdf` in the repo
root). Produce a SATs score (80–120) for every pupil, in every subject, from raw
assessment data in `atom-analytics-candidates.de_raw`. Graded on **structure,
judgement and clarity** — explicitly not on statistics. Roughly two hours of effort
expected.

Three hard requirements on the output:

- **Re-runnable** — running the models twice produces the same result.
- **Point-in-time** — a pupil's score can be recomputed as it stood on any date.
- **Production-ready shape** — migratable into the application database.

Deliverables: a GitHub repo with the SQL, a README covering what was built and the
assumptions, the AI planning artefacts (`docs/ai/`), and the models materialised in
BigQuery so reviewers can see the output.

---

## 2. Where things stand

| | |
|---|---|
| Profiling | Done. Three rounds, `sql/profiling/` |
| Design | Done. Four layers, sitting-grain event store, SCD2 output |
| Models | Done. 10 models, all building |
| Tests | Done. **101 data tests**, all passing (schema tests + 8 singular in `tests/`) |
| Seeds | Done, **but the conversion seed is interpolated — see §5** |
| Docs | Done, and trimmed for concision. README, SCORING, DATA_DICTIONARY, DECISIONS (D1–D41), GCSE_PREDICTION |
| Step 3 (GCSE) | Done. `docs/GCSE_PREDICTION.md`, linked from the README |
| Materialised | **Done, in `atom-analytics-candidates.tomi_odumuyiwa`.** `dbt build` reports 114 nodes: 10 models, 3 seeds, 101 data tests |
| Re-runnability | **Verified.** Full build then incremental build, byte-identical output |
| Incremental path | **Verified** in Atom's dataset, including partition pruning (22 KiB processed) |
| Git | Repository initialised for submission |

---

## 3. Environment — read before running anything

### Access

- **ADC is authenticated** (`gcloud auth application-default login`).
- **Build target is `atom-analytics-candidates.tomi_odumuyiwa`**, provisioned by
  Atom with BigQuery Data Editor. There is no permission to create other datasets,
  so every layer builds into this one via `single_dataset: true` (D41).
- `de_raw` is read-only.

### Running it

```bash
export ATOM_DBT_PROJECT="atom-analytics-candidates"
export ATOM_DBT_DATASET="tomi_odumuyiwa"
dbt build --vars '{single_dataset: true}'
```

`~/.dbt/profiles.yml` already exists and is gitignored. Installed: dbt-core 1.11.14,
dbt-bigquery 1.12.1, dbt_utils 1.4.1.

### Environment notes

1. **`location` must be `europe-west2`.** `de_raw` lives there, not in the `EU`
   multi-region, and BigQuery refuses a query that reads one location and writes
   another.

2. **BigQuery sandboxes** (projects without billing) forbid DML, and
   `insert_overwrite` is a MERGE. Earlier validation in a sandbox used
   `partition_models: false` (D36), which drops partitioning and incrementality
   together. Atom's dataset needs neither workaround.

3. **Sandboxes force a 60-day partition expiry that cannot be lifted.** The data
   spans ten months, so a *partitioned* build silently loses ~97% of rows — 61,296
   became 1,503 — and reports success. `assert_no_events_lost_in_staging` now catches
   this; see §7.

---

## 4. The design

**Store the events, not the answer.** A score is never written down and overwritten;
it is derived from the sittings up to a date. That delivers re-runnability,
point-in-time recomputation and scale from one structure rather than three.

Layers: **raw → staging → curated → modelled**. The boundary that does the work is
staging/curated — deduplicating repeated emissions is a *trustworthiness* decision so
it lives in staging; excluding Wellbeing is a *business* decision so it lives in
curated. That split is what keeps the scoring rule in exactly one file,
`cur_pupil_subject_scored.sql`.

**The grain is the sitting**, not the day (D28). The GOV.UK conversion table scores a
*paper*; a day is an accident of when someone logged in. Sitting grain is also
strictly finer, so a daily roll-up stays derivable.

**The headline score pools every question in the pupil's current term, to date**
(D29–D31). Not the last sitting — at ~25 questions its sampling noise is **3.47
scaled points, measured** across the 338 pupil-terms with three or more sittings, so
a pupil genuinely flat at 103 would appear to swing 96–110. Not lifetime either,
which lags badly. The pool sums *questions* rather than averaging sitting
percentages, and is term-**to-date** so every past date stays exact.

Terms are a calendar approximation — autumn Sep–Dec, spring Jan–Mar, summer Apr–Aug
— defined once in `macros/academic_calendar.sql`. Real term dates vary by school and
Easter moves; that is open question 8 for Atom.

Per-sitting scores are published too, in `pupil_subject_sitting_scores` — the
trajectory. The line is meaningful; the individual points are noisy.

---

## 5. The one outstanding correctness risk

**`seeds/seed_sats_conversion.csv` is reconstructed, not transcribed.** GOV.UK
publishes the 2026 KS2 conversion tables as a web page, and the session that built
this had only the anchor points. `scripts/generate_conversion_seed.py` rebuilds the
full mark-by-mark curve from them: exact at every published anchor (maxima, the 100
and 110 thresholds, the 3-mark minimum, and 15 percentage checkpoints per paper, all
asserted before it writes anything) and **linearly interpolated between them**, worth
about a scaled point in the middle of the range.

This is disclosed in README §7 and SCORING §3. Replacing the anchors with a full
transcription of the published page is a ten-minute job, and the script's assertions
will hold it honest.

---

## 6. Verified output

From the build on 22–23/09/2026, `partition_models: false`, full data:

| Table | Rows |
|---|---|
| `stg_responses` | 61,296 (63,707 source less 2,411 duplicate emissions) |
| `cur_responses_enriched` (view) | 61,296 |
| `cur_pupil_subject_sitting` | 2,486 |
| `cur_pupil_subject_scored` | 2,486 |
| `pupil_subject_sats_history` | 1,365 |
| `pupil_subject_sats_current` | 1,694 (242 pupils × 7 subjects) |
| `pupil_subject_sitting_scores` | 2,486 |

English 102.8 mean (153 scored, plus 1 `below_minimum_raw_score`), Maths 101.6 (152),
Year 6 104.7. Every figure matched what profiling predicted before anything ran.

---

## 7. Lessons from the build

**Only a real run surfaced some issues:** the region mismatch, Science as a seventh
subject with no responses (D35), 12 sittings with a NULL `started_at`, and the
checksum overflowing INT64 (now cast to NUMERIC).

**A truncated build passed every test.** When the sandbox expiry deleted 97% of rows,
every other test still passed, because a truncated table is consistent with itself.
`assert_no_events_lost_in_staging` (D37) reconciles staged rows against the source.

---

## 8. Next actions, in order

1. **Replace the conversion seed anchors** with a full transcription (§5).
2. Split English into reading and GPS if topic names become available.

Discussed but not done: renaming `is_reliable` to something that says reliable *in
what sense* (`has_sufficient_evidence`), and holding real term dates as a seed.

---

## 9. Standing constraints

- Every figure quoted in the documentation must trace to a query in `sql/profiling/`
  or to a verified build. No numbers from memory.
- British English throughout.
- Keep it proportionate to a two-hour brief. Single-source anything that appears
  twice.
- Column names are spelled out, not abbreviated — `number_of_sittings`, not
  `n_sittings`. Source column names are the exception: `question_number` stays as it
  is wherever `de_raw` is read directly.

---

## 10. Repository map

```
README.md                  what was built, findings, assumptions, how to run
dbt_project.yml            layers, vars (conversion_year, min_responses,
                           lookback_days, partition_models)
packages.yml               dbt_utils
profiles.yml.example       connection template (real file gitignored)
macros/
  academic_calendar.sql    the term definition, in one place
models/
  staging/     stg_*       dedupe, cast, flag
  curated/     cur_*       joins, sitting grain, scoring
  modelled/                pupil_subject_sats_history / _current /
                           pupil_subject_sitting_scores
seeds/                     conversion tables + subject mapping
scripts/
  generate_conversion_seed.py    rebuilds the seeds, asserts every documented figure
sql/profiling/             the three profiling rounds
tests/                     8 singular tests
docs/
  SCORING.md               method, conversion tables, limitations, 9 open questions
  DATA_DICTIONARY.md       grains, join paths, output contract
  DECISIONS.md             D1-D41, every judgement call
  GCSE_PREDICTION.md       Step 3
  ai/                      this file, plus the planning and session records
```
