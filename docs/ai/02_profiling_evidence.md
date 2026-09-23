# Profiling evidence

Raw outputs from `sql/profiling/`, kept so every figure quoted in the README can be
traced. Query numbers refer to the sections in those files.

## Query index

What each query was for and what it found. Full SQL in `sql/profiling/`.

| Query | Question it answers | Finding |
|---|---|---|
| `00` §0 | How big is everything? | 63,707 / 2,509 / 242 / 10,552 |
| `00` §1 | Are responses clean? | 2,411 surplus duplicate rows; no messy IDs |
| `00` §2 | Are sittings clean? | 25 impossible year groups; `total_questions` unreliable |
| `00` §3 | Are pupils clean? | No duplicates, nothing deleted |
| `00` §4 | Is the hierarchy a clean tree? | Yes; 6 subjects; no topic names |
| `00` §5 | Do the tables join? | 1,433 orphan responses; universal `session_type` mismatch |
| `00` §6 | What will scoring look like? | ~58% correct, flat Y1–5, jump at Y6 |
| `01` §1 | Is the `session_type` mismatch real? | No — two constants, two vocabularies |
| `01` §2 | Are the over-count sittings retries or extra questions? | Neither: duplicate emissions of one event |
| `01` §3 | Where did the orphans come from? | Deleted sittings, not a load boundary |
| `01` §4 | Are the odd year groups typos? | No — test pupils with no responses |
| `01` §5 | Is Wellbeing really the survey? | Yes, exactly |
| `01` §6 | Can English be split into reading and GPS? | No — topic IDs only, no names |
| `01` §7 | Are zero-second answers suspicious? | No — mostly no-attempts |
| `01` §9 | Does the daily grain work? | Yes — 1,568 rows, 40.6 responses each |
| `02` §1 | Confirm the zero-second explanation | 58.9% vs 59.8% baseline, 0 contradictions |
| `02` §2 | What does the dedupe tie-break cost? | 1.79pp mean, 8.06pp worst |
| `02` §3 | Can year group be imputed? | 38 of 44 pupils unambiguous |

---

## Round 1 — `00_profiling.sql`

**0.1 Row counts**

| table | rows |
|---|---|
| responses | 63,707 |
| assessment_sittings | 2,509 |
| pupils | 242 |
| course_hierarchy | 10,552 |

**2.3 Year groups at sitting**

| year_group | sittings |
|---|---|
| 1 | 244 |
| 2 | 416 |
| 3 | 371 |
| 4 | 542 |
| 5 | 459 |
| 6 | 452 |
| 11 | 10 |
| 14 | 5 |
| 15 | 10 |

Sums to 2,509, so no NULLs. UK year groups stop at 13, so 14 and 15 are impossible.

**5.1 Cross-table integrity**

| check | rows |
|---|---|
| responses | 63,707 |
| no matching sitting | 1,433 |
| no matching question | 0 |
| no matching pupil | 0 |
| pupil differs from sitting | 0 |
| session_type differs from sitting | 62,274 |
| in deleted sitting | 0 |
| in incomplete sitting | 31 |
| from deleted pupil | 0 |
| question_number exceeds total | 0 |
| answered before sitting started | 0 |
| answered after sitting finished | 1,608 |

63,707 − 1,433 = 62,274. Every joinable row disagrees on `session_type`, which is
what identified it as a vocabulary difference rather than an error. All 1,608
after-finish rows are 1 second late.

**5.3 Orphans in the other direction**

| check | rows |
|---|---|
| sittings without responses | 79 |
| sittings with unknown pupil | 0 |
| pupils without responses | 78 |

**5.4 Responses per sitting vs `total_questions`**

| is_complete | bucket | sittings |
|---|---|---|
| FALSE | no responses | 11 |
| FALSE | fewer than total | 1 |
| FALSE | exactly total | 1 |
| TRUE | no responses | 68 |
| TRUE | fewer than total | 9 |
| TRUE | exactly total | 1,672 |
| TRUE | more than total | 747 |

**5.5 Subjects per sitting** — 2,486 sittings, all single-subject.

**6.1 Evidence per pupil per subject**

| subject | pupils | under 20 responses |
|---|---|---|
| English | 154 | 1 |
| Maths | 152 | 0 |
| Screeners | 82 | 0 |
| Wellbeing | 129 | 0 |
| Verbal Reasoning | 8 | 0 |
| Non-Verbal Reasoning | 3 | 0 |

**6.2 Percentage correct by subject and year group** (abridged)

| subject | Y1 | Y2 | Y3 | Y4 | Y5 | Y6 |
|---|---|---|---|---|---|---|
| English | 56.3 | 56.2 | 57.5 | 52.2 | 56.9 | 66.5 |
| Maths | 56.1 | 53.4 | 58.8 | 54.9 | 57.3 | 66.4 |
| Screeners | — | — | 42.3 | 52.9 | 48.0 | 64.5 |
| Wellbeing | 59.0 | 56.3 | 67.5 | 58.3 | 59.5 | 66.1 |

Flat through Years 1–5, then a jump in Year 6 across every subject — the basis for
the year-calibrated-content argument in `docs/SCORING.md` §4.

Blank year group rows total 889 + 307 + 141 + 96 = 1,433, matching the orphan count
exactly.

**6.3 By session type and style**

| session_type | style | responses | pct correct |
|---|---|---|---|
| summative_assessment | fixed_question | 58,338 | 56.8 |
| summative_assessment | survey | 3,936 | 61.3 |

---

## Round 2 — `01_profiling_followups.sql`

**1. Session type crosstab** — `MOCK_TEST` → `summative_assessment` for all 62,274
joinable rows. Both columns constant.

**2.1 Cause of the 747 over-count sittings**

| check | count |
|---|---|
| sittings over total | 747 |
| explained by repeated questions | 747 |
| genuinely extra questions | 0 |
| duplicate response_ids | 0 |

**2.2 Anatomy of the repeats**

| copies | pairs | same response_id | outcome changed | gap seconds (quartiles) |
|---|---|---|---|---|
| 2 | 1,837 | 0 | 799 | 0,0,0,0,0 |
| 3 | 193 | 0 | 123 | 0,0,0,0,0 |
| 4 | 20 | 0 | 14 | 0,0,0,0,0 |
| 5 | 32 | 0 | 29 | 0,0,0,0,0 |

2,082 pairs, ~2,411 surplus rows, 965 conflicting. Zero gap at every quartile is
what rules out retries.

**3.1 Orphan response profile**

1,433 responses, 56 unknown sessions, 44 pupils, all of whom have other sittings.
Range 11/11/2025 to 12/06/2026, inside the sittings window (10/11/2025 to
14/09/2026). Not a load boundary.

**4. Impossible year groups** — 25 sittings, 5 pupils, dated 02–03/09/2026, **no
responses at all**. Each pupil has a single constant odd year group across 5
sittings, so not a typo in an otherwise sane history.

**8. Sittings with no responses** — all dated Aug–Sep 2026, and the only place
`adaptive` and `non_adaptive` styles appear.

**9. Daily grain check** — 1,568 rows, 164 pupils, 51 active days, 40.6 responses
per row on average.

---

## Round 3 — `02_verification.sql`

**1. Zero-second explanation**

| check | value |
|---|---|
| contradictions (no attempt but correct) | 0 |
| no-attempts marked wrong | 3,279 |
| no-attempts at zero seconds | 2,303 |
| attempted at zero seconds | 878 |
| pct correct, attempted at zero seconds | 58.9 |
| pct correct, baseline over 10s | 59.8 |

**2. Dedupe sensitivity**

| subject | pupil-subjects | affected | mean spread (pp) | worst (pp) |
|---|---|---|---|---|
| English | 154 | 141 | 1.79 | 5.52 |
| Maths | 152 | 136 | 1.75 | 8.06 |
| Verbal Reasoning | 8 | 5 | 15.79 | 30.26 |
| Screeners / Wellbeing / NVR | — | 0 | 0 | 0 |

**3. Year group imputation** — 44 pupils, 38 unambiguous within an academic year, 6
needing the nearest-sitting rule.
