# Implementation session

The second AI session, which wrote the models. `01_planning_and_prompts.md` covers
the first (design and profiling).

Session date: 22–23/09/2026. Claude Opus 5 in Claude Code, working on the repo
directly.

---

## The handover

The first session ended with design, profiling and docs, but only one model written.
Rather than continue in the same conversation, it wrote `CONTEXT.md` as a
standalone brief, and a fresh session started from that file, the task PDF and the
docs, with no memory of the reasoning behind any of it.

The test: could a fresh session build the right thing without re-arguing decisions?

**What carried:** the layer structure, the event-store design, every decision with
its reasoning, and the profiling figures. None of it had to be rediscovered.

**What didn't:** the full conversion table. The handover had only its anchor points.

---

## The seed problem

With only the anchors (maxima, 100 and 110 thresholds, 3-mark minimum, a
percentage-to-score table per paper) and no access to the GOV.UK page, there were
three options:

1. Write the full table from general knowledge and label it as published data.
   **Rejected.** Invented numbers presented as an official table get copied onward
   and believed.
2. Leave the seed out. Honest, but the pipeline would be unbuildable and unreviewable.
3. Generate the curve from the anchors, assert every published figure is reproduced
   exactly, and label the interpolation clearly.

Option 3 became `scripts/generate_conversion_seed.py`. Before writing anything, it
asserts all 45 percentage checkpoints, the maxima, the thresholds, the minimum-mark
rule and monotonicity. Swapping in a full transcription means editing one dictionary.

The assertions caught two errors in the docs: the seed has **233 rows, not 234**
(51 + 71 + 111), and a summary row that was **impossible** (reading at 106 for 66%,
when 65% and 66% of 50 marks both round to 33). The docs were corrected to match the
artefact, and both are now asserted so they can't drift.

---

## Decisions taken during implementation

These came up only once the models were being written (D21–D24).

**`stg_responses` is a partitioned table, not a view (D21).** The dedupe window
partitions by `(session_id, question_id)`, so a date filter can't push below it, and
at 100m rows every read would rescan everything. It's safe to deduplicate per day
because a profiling finding shows duplicate copies share an identical
`answered_at`, so they always land in the same partition.

**No load timestamps (D22).** The instinct is to add `inserted_at` to anything bound
for an application database. Here it would contradict re-runnability: two runs would
differ by construction.

**What counts as a new history version (D23).** Versioning on any change would
reproduce the sitting grain. Versioning on score change compresses well, but means
counts describe the state at `valid_from`. We chose the second and documented it.

**NULL rather than FALSE for the standards flags (D24).** FALSE on an unscored pupil
asserts they failed. That's the wrong claim on a teacher-facing dashboard.

---

## The grain changed after review

The first build used a daily grain with a lifetime-cumulative score. Reviewing it, I
asked: *why not score each sitting, since that gives trajectory for free?*

That was right about the grain, for a reason neither session had put into words:
**the conversion table scores a paper.** Applying it to a lifetime pool of ~400
questions stretches it past what it means. A sitting is a test; a day is an accident
of when someone logged in. The sitting grain is also finer, so daily roll-ups remain
possible.

The AI pushed back on using the latest sitting as the headline score. At ~25
questions a sitting carries about ±3 scaled points of noise, so a pupil flat at 103
would appear to swing 96–110. The settled design pools every question in the current
term, to date:

- **Pool questions, not percentages.** A 40-question sitting tells us four times as
  much as a 10-question one.
- **Term-to-date, not whole-term.** Whole-term is only right on the last day of term,
  which would break point-in-time.

`assert_term_pool_resets_each_term` guards the one failure this adds: a window frame
that leaks across terms, leaving every score plausible but silently too smooth.

---

## Validating without a dataset

Access was read-only: `de_raw` and `bigquery.jobs.create`, but no candidate dataset
and no permission to create one.

Rather than stop, `scripts/validate_against_bigquery.py` stitches each model and its
upstream models into one query, with the seeds inlined. Those dry-run for free
(checking every column and type against the real schemas) and then execute, since a
SELECT needs no write access.

All ten models validated, and the output matched predictions written down before
anything ran: 2,486 sittings, English 102.8, Maths 101.6, Year 6 104.7 against a
predicted 103–105.

It also turned an estimate into evidence. The case for pooling a term rested on
single-sitting noise of about ±3 points from sampling theory. Measured across 338
pupil-terms with three or more sittings, it is **3.47**.

---

## The real build

The models were then built in a personal GCP project. Running them surfaced issues
that reading the code couldn't:

- **Region.** `de_raw` is in `europe-west2`, and BigQuery won't read one location and
  write another. The profile template was corrected.
- **Science.** The catalogue has seven subjects, not six. Science has 335 questions
  and no responses, so activity-based profiling never saw it. The relationship test
  caught it at build time, which is exactly what it was written for (D25, D35).
- **12 sittings with a NULL `started_at`.** The date fallback already handled them.
  Only a staging test needed relaxing.
- **The checksum query overflowed INT64** at 61k rows. It now casts to NUMERIC.

The most important finding: a BigQuery sandbox silently deleted 97% of the rows
through a forced 60-day partition expiry, and **every test still passed**. They check
uniqueness, ranges, integrity and consistency, and a truncated table is consistent
with itself. `assert_no_events_lost_in_staging` (D37) now reconciles against the
source.

After that, two full builds produced byte-identical output, with all 97 tests
passing.

---

## Simplification pass

A final review aimed at making the models as simple and efficient as possible:

- **`cur_responses_enriched` became a view (D38).** As a table, it was a full
  100m-row rebuild on every run, which undid the incremental models either side
  of it.
- **Incremental edge case fixed (D39).** The sitting model now writes only
  sittings that started inside the lookback window, so a sitting straddling the
  cutoff can't overwrite its partition with partial counts.
- **Year-group imputation moved to the 56 missing sittings (D26)**, instead of
  scanning every response to find orphans.
- **Every pupil in every subject (D40).** The current view now starts from
  pupils × subjects: 1,694 rows, with `no_responses` where there's no activity.
- Unused columns removed, scoring `CASE`s simplified, and the temporary read-only
  validation script deleted now that `dbt build` runs.

Verified against a snapshot of the previous outputs: every score, window, count
and year group is identical. The 528 previous current rows are unchanged, and
1,166 `no_responses` rows were added. All 101 tests pass, and two builds are
byte-identical.

---

## The build in Atom's dataset

Atom provisioned `tomi_odumuyiwa`. The first attempt was denied: the dataset
granted `roles/editor`, a project-level role that carries no permissions on a single
dataset. Diagnosing it from the dataset's access list and a permissions check led
to a specific request for BigQuery Data Editor, which fixed it.

With only one dataset, a `generate_schema_name` override (`single_dataset`, D41)
builds every layer into it.

This was the first environment that allows DML, so it closed the last open item:

- **A full build, then an incremental build**, produced identical checksums on all six
  tables. The incremental models ran as real `insert_overwrite` merges.
- **Partition pruning works.** The sitting model processed 22 KiB, the last seven
  days of `stg_responses`, through the `cur_responses_enriched` view.
- **The checksums match the earlier sandbox builds exactly**, so the output is the
  same in both environments.
