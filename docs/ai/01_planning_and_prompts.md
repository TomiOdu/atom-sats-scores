# Planning log and prompts

How the design and profiling work was driven, including how two plausible readings
of the data were tested and ruled out.

Session date: 22/09/2026 - 23/09/2026. Model: Claude Opus 4.6 & Opus 5.5.

---

## Round 1: Approach

**Prompt (paraphrased):** Outline an approach for this take-home.

**What came out:** the layered structure, the store-events-not-answers idea, the
SCD2 output shape and a time budget. It also put **profiling first**, before any
models. "Interpret the tables as you find them" implies planted data quality issues.

**Changed later:** the staging/intermediate/marts naming became
raw/staging/curated/modelled, to match the convention I use at work. That forced a
better split (Round 5).

---

## Round 2: Profiling sweep

**Prompt:** Generate SQL to explore the data, given these four table schemas.

**Output:** `sql/profiling/00_profiling.sql`, about 30 standalone queries covering row
counts, each table, cross-table integrity and early signals for scoring. Each query
has a "Look for" comment.

---

## Round 3: Testing interpretations before relying on them

I fed the outputs back with my initial read. The follow-ups in
`01_profiling_followups.sql` were written to **test** two hypotheses, not confirm
them. Both were ruled out.

**Are the 517 correct zero-second answers automated?** Bucketing `seconds_taken` against
correctness showed 73% of zero-second rows are skipped questions, and the rest score
58.9% against a 59.8% baseline, with no contradictions. It was a timer that failed to
record. Nothing excluded.

**Does the `session_type` mismatch mean corrupted data?** 62,274 of 63,707 responses
disagreed with their sitting, and 63,707 − 1,433 orphans = 62,274 exactly, so
_every_ joinable row disagreed. Both columns are constants in different vocabularies.
Not corruption.

**Reconciling totals caught more than any single query.** The 1,433 orphan responses
exactly match the blank-year-group rows (889 + 307 + 141 + 96). Wellbeing responses
minus orphans (4,032 − 96) exactly match the survey count (3,936), which identified
Wellbeing as a survey. When two numbers agree exactly, it is usually a mechanism,
not a coincidence.

---

## Round 4: Settling the judgement calls

The duplicates were not retries: identical `answered_at`, `seconds_taken` and
`question_number`, differing only in `response_id`, and half disagreed on
`is_correct`. That ruled out `ORDER BY answered_at` as a tie-break, leaving
`response_id`.

Rather than assert that was right, `02_verification.sql` measures the cost by
scoring every pupil three ways (optimistic, pessimistic, deterministic). The average
spread is 1.8pp for scored subjects. Verbal Reasoning showed 15.8pp because its
pupils have few responses, which became the evidence for the reliability flag.

---

## Round 5: Structure and scoring

**Prompt:** model it as raw → staging → curated → modelled.

In the three-layer version, one table did both the scoring and the validity windows.
Splitting curated from modelled moved scoring into `cur_pupil_subject_scored`, so
the rule lives in one place.

**Prompt:** build the scoring from what GOV.UK publishes, and flag questions for
Atom.

The 2026 KS2 conversion tables (published 16/07/2026) were researched and their
anchor points recorded (`03_scoring_research.md`). Two findings only showed up with
the tables in hand:

- Reading and GPS curves are within one scaled point everywhere, so the "which
  English paper?" question costs about a point. An open assumption became a
  quantified one.
- Maths is compressed: raw 56–94 maps to scaled 100–110.

---

## How AI was used, and where it wasn't

**Used for:** structuring the profiling so coverage was systematic, query
boilerplate, pressure-testing interpretations, extracting the GOV.UK figures, and
drafting documentation.

**Not used for:** deciding what the numbers mean. Every interpretation was checked
against a query, and every README figure traces to `sql/profiling/`. Where a call was
arguable, its cost was measured.

**Working pattern:** query → paste raw output → interpret → write the next query to
test the interpretation.
