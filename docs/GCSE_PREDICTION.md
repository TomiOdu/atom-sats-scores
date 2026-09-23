# Predicting GCSE results from primary-school work

Step 3 of the brief: what I would build and what it would need. Not implemented.

**The starting point.** KS2 attainment already predicts GCSE outcomes well — it is
what Progress 8 is built on. So the question is not whether primary work predicts
GCSEs, but what Atom's data adds. Five years separate Year 6 from GCSEs, and the
biggest influences in that gap (secondary school, teaching, attendance) are not in
this data. The output should be a grade band with an honest interval and its main
drivers — "on a path that usually leads to a grade 4" — not a point estimate a
teacher would treat as fact.

**What data.** The binding constraint is matched outcomes: pupils with both Atom
history and actual GCSE grades. Without them there is nothing to fit or validate
against. Partner schools sharing results is the direct route, but slow. The faster
route is a bridge: link Atom scores to real KS2 results, then use the DfE's
published KS2-to-KS4 transition matrices for the rest, so only the Atom-to-KS2 step
is ours to prove. The features worth adding on top are the scaled scores this
pipeline already produces, trajectory (rising or falling, from the per-sitting
scores), topic-level mastery (fractions gate most of secondary maths — this needs
topic names `course_hierarchy` lacks), and engagement signals already in the data
such as `is_no_attempt`.

**What assumptions, and why they matter.** That the primary-to-GCSE relationship is
stable over time, when curricula change and 2020–21 sits inside any training window
— so the model needs re-fitting and drift monitoring. That Atom users resemble the
national population, which they probably do not. That the outcomes are not shaped
by the predictions themselves — if teachers act on a prediction, it changes the
result, so we should record when each one was shown. And that percentage correct
is comparable across pupils, which the flat Year 1–5 percentages (`SCORING.md` §4)
call into question.

**What I would build.** Start with maths only. The baseline is the transition
matrix applied to our predicted KS2 score, and each Atom feature earns its place
only by beating it on a later cohort — split by time, not at random, because that
is how the model will be used. It fits the existing design:
`cur_pupil_subject_sitting` is already a point-in-time feature store, which stops
training data leaking the future, and a prediction table would keep history in the
same valid-from / valid-to shape as `pupil_subject_sats_history`. Before anyone
sees it, check it is equally accurate across groups of pupils: a model that is
quietly pessimistic about one group, used to direct teacher attention, does real
harm.
