/*
    Round 1 - first sweep of atom-analytics-candidates.de_raw.

    Standalone queries, run one at a time in the BigQuery console. Each carries a
    "Look for" note recording what it was written to find out, so the sweep reads
    as a set of questions rather than a pile of SQL.

    Written before any modelling. The brief says "interpret the tables as you
    find them", which is usually a signal that something has been planted, so
    the first job was coverage: row counts, one section per table, cross-table
    integrity, and early signals for the scoring design.

    Outputs are recorded in docs/ai/02_profiling_evidence.md.

    BigQuery bills by columns scanned, and LIMIT does not reduce that, so every
    query below selects only the columns it needs - irrelevant at 64k rows, not
    at the 100m+ the brief anticipates.
*/

---------------------------------------------------------------------------
-- 0. How big is everything?
---------------------------------------------------------------------------

-- 0.1 Row counts.
-- Look for: the grain of each table, and whether anything is surprisingly large.
-- Found: 63,707 / 2,509 / 242 / 10,552.
select 'responses' as table_name, count(*) as rows from `atom-analytics-candidates.de_raw.responses`
union all
select 'assessment_sittings', count(*) from `atom-analytics-candidates.de_raw.assessment_sittings`
union all
select 'pupils', count(*) from `atom-analytics-candidates.de_raw.pupils`
union all
select 'course_hierarchy', count(*) from `atom-analytics-candidates.de_raw.course_hierarchy`
order by table_name;


---------------------------------------------------------------------------
-- 1. responses
---------------------------------------------------------------------------

-- 1.1 Is response_id the grain, and is (session, question) the grain?
-- Look for: a gap between the two, which would mean the table is not one row
-- per answer.
-- Found: response_id is unique; 2,411 surplus rows against (session, question).
select
    count(*) as rows,
    count(distinct response_id) as distinct_response_ids,
    count(distinct concat(cast(session_id as string), '|', cast(question_id as string)))
        as distinct_session_question_pairs,
    count(*) - count(distinct concat(cast(session_id as string), '|', cast(question_id as string)))
        as surplus_rows
from `atom-analytics-candidates.de_raw.responses`;

-- 1.2 Nulls and value distributions on the columns scoring depends on.
-- Look for: nulls in is_correct or is_no_attempt, which would force a decision
-- about how to count them.
select
    countif(response_id is null) as null_response_id,
    countif(pupil_id is null) as null_pupil_id,
    countif(session_id is null) as null_session_id,
    countif(question_id is null) as null_question_id,
    countif(is_correct is null) as null_is_correct,
    countif(is_no_attempt is null) as null_is_no_attempt,
    countif(seconds_taken is null) as null_seconds_taken,
    countif(answered_at is null) as null_answered_at
from `atom-analytics-candidates.de_raw.responses`;

-- 1.3 Can a pupil be marked correct on a question they did not attempt?
-- Look for: contradictions, which would undermine counting no-attempts as wrong.
-- Found: zero.
select
    countif(is_no_attempt and is_correct) as no_attempt_but_correct,
    countif(is_no_attempt and not is_correct) as no_attempt_and_wrong,
    countif(not is_no_attempt) as attempted
from `atom-analytics-candidates.de_raw.responses`;

-- 1.4 seconds_taken distribution.
-- Look for: negatives (impossible) and zeros (suspicious until explained).
-- Found: no negatives; 3,156 zeros. Explained in 01 section 7 and 02 section 1.
select
    countif(seconds_taken < 0) as negative,
    countif(seconds_taken = 0) as zero,
    countif(seconds_taken is null) as null_value,
    min(seconds_taken) as min_seconds,
    approx_quantiles(seconds_taken, 4) as quartiles,
    max(seconds_taken) as max_seconds
from `atom-analytics-candidates.de_raw.responses`;

-- 1.5 Date range and how concentrated the activity is.
-- Look for: whether a daily grain is sensible, or whether activity is so sparse
-- that a coarser one would do.
-- Found: 10/11/2025 to 16/09/2026 across 51 active days.
select
    min(answered_at) as first_response,
    max(answered_at) as last_response,
    count(distinct date(answered_at)) as active_days
from `atom-analytics-candidates.de_raw.responses`;

-- 1.6 Is session_type informative?
-- Look for: more than one value. A practice-vs-assessment distinction would
-- change what counts as evidence.
-- Found: constant 'MOCK_TEST'.
select session_type, count(*) as rows
from `atom-analytics-candidates.de_raw.responses`
group by 1 order by 2 desc;


---------------------------------------------------------------------------
-- 2. assessment_sittings
---------------------------------------------------------------------------

-- 2.1 Is session_id the grain?
select count(*) as rows, count(distinct session_id) as distinct_sessions
from `atom-analytics-candidates.de_raw.assessment_sittings`;

-- 2.2 Styles and session types present.
-- Look for: styles that imply different scoring semantics.
-- Found: fixed_question, survey, and adaptive / non_adaptive on a small group
-- that turns out to be test data (see 01 section 8).
select style, session_type, count(*) as sittings
from `atom-analytics-candidates.de_raw.assessment_sittings`
group by 1, 2 order by 3 desc;

-- 2.3 Year groups at sitting.
-- Look for: values outside the English 1-13 range.
-- Found: 11, 14 and 15. 14 and 15 do not exist.
select year_group_at_sitting, count(*) as sittings
from `atom-analytics-candidates.de_raw.assessment_sittings`
group by 1 order by 1;

-- 2.4 Is total_questions consistent for a given assessment?
-- Look for: whether total_questions is a property of the assessment or of the
-- sitting, which decides whether it can be used as a denominator.
-- Found: mostly consistent, one exception - and unreliable either way (see 5.4).
select
    assessment_id,
    count(*) as sittings,
    count(distinct total_questions) as distinct_totals,
    min(total_questions) as min_total,
    max(total_questions) as max_total
from `atom-analytics-candidates.de_raw.assessment_sittings`
group by 1
having count(distinct total_questions) > 1
order by sittings desc;

-- 2.5 Timestamp sanity and completion.
-- Look for: sittings that finish before they start, and how many never finished.
-- Found: none finish before they start.
select
    countif(finished_at < started_at) as finished_before_started,
    countif(finished_at is null) as never_finished,
    countif(not is_complete) as not_complete,
    countif(is_deleted) as deleted,
    min(started_at) as first_sitting,
    max(started_at) as last_sitting
from `atom-analytics-candidates.de_raw.assessment_sittings`;


---------------------------------------------------------------------------
-- 3. pupils
---------------------------------------------------------------------------

-- 3.1 Grain and deletions.
-- Look for: duplicate pupils, and whether is_deleted is ever set.
-- Found: 242 distinct, none deleted. The filter is retained anyway (D19).
select
    count(*) as rows,
    count(distinct pupil_id) as distinct_pupils,
    countif(is_deleted) as deleted_pupils
from `atom-analytics-candidates.de_raw.pupils`;


---------------------------------------------------------------------------
-- 4. course_hierarchy
---------------------------------------------------------------------------

-- 4.1 Grain.
select count(*) as rows, count(distinct question_id) as distinct_questions
from `atom-analytics-candidates.de_raw.course_hierarchy`;

-- 4.2 Is the hierarchy a clean tree, or does a child have two parents?
-- Look for: an atom under two subtopics, a topic under two subjects. Any of
-- those would make "the subject of a question" ambiguous.
-- Found: clean.
select
    count(*) as rows,
    count(distinct atom_id) as atoms,
    count(distinct subtopic_id) as subtopics,
    count(distinct topic_id) as topics,
    count(distinct subject_id) as subjects,
    count(distinct concat(cast(atom_id as string), '|', cast(subtopic_id as string))) as atom_subtopic_pairs,
    count(distinct concat(cast(subtopic_id as string), '|', cast(topic_id as string))) as subtopic_topic_pairs,
    count(distinct concat(cast(topic_id as string), '|', cast(subject_id as string))) as topic_subject_pairs
from `atom-analytics-candidates.de_raw.course_hierarchy`;

-- 4.3 The subjects, and how much of the bank sits under each.
-- Found: SEVEN subjects. Only English and Maths have a KS2 SATs equivalent.
-- Science has 335 questions and zero responses, so it is invisible to any query
-- that starts from activity - it only shows up where the catalogue is counted
-- directly, as here (D35).
select
    subject_id,
    subject_name,
    count(distinct topic_id) as topics,
    count(*) as questions
from `atom-analytics-candidates.de_raw.course_hierarchy`
group by 1, 2 order by questions desc;

-- 4.4 Is a subject name ever attached to more than one subject_id, or vice versa?
-- Look for: a reason not to key the subject mapping seed on the name.
select
    count(distinct subject_id) as subject_ids,
    count(distinct subject_name) as subject_names,
    count(distinct concat(cast(subject_id as string), '|', subject_name)) as pairs
from `atom-analytics-candidates.de_raw.course_hierarchy`;


---------------------------------------------------------------------------
-- 5. Do the tables join?
---------------------------------------------------------------------------

-- 5.1 Cross-table integrity, every check in one row so the totals can be
-- reconciled against each other.
-- Look for: orphans in any direction, and disagreements between a response and
-- its parent sitting.
-- Found: 1,433 orphan responses; a universal session_type disagreement, which
-- 63,707 - 1,433 = 62,274 identifies as a vocabulary difference rather than an
-- error - see 01 section 1.
select
    count(*) as responses,
    countif(s.session_id is null) as no_matching_sitting,
    countif(c.question_id is null) as no_matching_question,
    countif(p.pupil_id is null) as no_matching_pupil,
    countif(s.session_id is not null and r.pupil_id != s.pupil_id) as pupil_differs_from_sitting,
    countif(s.session_id is not null and r.session_type != s.session_type) as session_type_differs,
    countif(s.is_deleted) as in_deleted_sitting,
    countif(s.session_id is not null and not s.is_complete) as in_incomplete_sitting,
    countif(p.is_deleted) as from_deleted_pupil,
    countif(s.session_id is not null and r.question_number > s.total_questions) as question_number_exceeds_total,
    countif(r.answered_at < s.started_at) as answered_before_sitting_started,
    countif(r.answered_at > s.finished_at) as answered_after_sitting_finished
from `atom-analytics-candidates.de_raw.responses` r
left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
left join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
left join `atom-analytics-candidates.de_raw.pupils` p on r.pupil_id = p.pupil_id;

-- 5.2 How late are the "answered after the sitting finished" rows?
-- Look for: whether this is clock skew or something structural.
-- Found: all 1,608 are exactly 1 second late. Skew, tolerated.
select
    timestamp_diff(r.answered_at, s.finished_at, second) as seconds_after_finish,
    count(*) as responses
from `atom-analytics-candidates.de_raw.responses` r
join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
where r.answered_at > s.finished_at
group by 1 order by 1;

-- 5.3 Orphans in the other direction.
-- Look for: sittings and pupils with nothing attached, which affect coverage
-- rather than correctness.
-- Found: 79 response-less sittings, 78 pupils with no responses at all.
select
    (select count(*) from `atom-analytics-candidates.de_raw.assessment_sittings` s
     where not exists (select 1 from `atom-analytics-candidates.de_raw.responses` r
                       where r.session_id = s.session_id)) as sittings_without_responses,
    (select count(*) from `atom-analytics-candidates.de_raw.assessment_sittings` s
     where not exists (select 1 from `atom-analytics-candidates.de_raw.pupils` p
                       where p.pupil_id = s.pupil_id)) as sittings_with_unknown_pupil,
    (select count(*) from `atom-analytics-candidates.de_raw.pupils` p
     where not exists (select 1 from `atom-analytics-candidates.de_raw.responses` r
                       where r.pupil_id = p.pupil_id)) as pupils_without_responses;

-- 5.4 Responses per sitting against total_questions.
-- Look for: whether total_questions can serve as a scoring denominator.
-- Found: 747 sittings have MORE responses than questions, which is what led to
-- the duplicate-emission finding. 9 have fewer. total_questions is not usable.
with response_counts as (
    select session_id, count(*) as number_of_responses
    from `atom-analytics-candidates.de_raw.responses`
    group by 1
)
select
    s.is_complete,
    case
        when rc.number_of_responses is null then 'no responses'
        when rc.number_of_responses < s.total_questions then 'fewer than total'
        when rc.number_of_responses = s.total_questions then 'exactly total'
        else 'more than total'
    end as bucket,
    count(*) as sittings
from `atom-analytics-candidates.de_raw.assessment_sittings` s
left join response_counts rc using (session_id)
group by 1, 2 order by 1, 3 desc;

-- 5.5 Does a sitting ever cover more than one subject?
-- Look for: whether subject can be taken from the sitting or must come from the
-- question. The model takes it from the question regardless, but a mixed sitting
-- would make the choice load-bearing.
-- Found: 2,486 sittings, all single-subject.
select
    count(*) as sittings_with_responses,
    countif(subjects > 1) as multi_subject_sittings
from (
    select r.session_id, count(distinct c.subject_id) as subjects
    from `atom-analytics-candidates.de_raw.responses` r
    join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
    group by 1
);


---------------------------------------------------------------------------
-- 6. Early signals for the scoring design
---------------------------------------------------------------------------

-- 6.1 How much evidence is there per pupil per subject?
-- Look for: pupil-subjects thin enough that a percentage would be noise. This is
-- what the reliability flag was built for.
-- Found: one English pupil with 6 responses; everyone else above 20.
with per_pupil_subject as (
    select
        c.subject_name,
        r.pupil_id,
        count(*) as number_of_responses
    from `atom-analytics-candidates.de_raw.responses` r
    join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
    group by 1, 2
)
select
    subject_name,
    count(*) as pupils,
    countif(number_of_responses < 20) as under_20_responses,
    min(number_of_responses) as min_responses,
    round(avg(number_of_responses), 1) as avg_responses,
    max(number_of_responses) as max_responses
from per_pupil_subject
group by 1 order by pupils desc;

-- 6.2 Percentage correct by subject and year group.
-- Look for: the shape a score would take, and whether percentage is comparable
-- across year groups.
-- Found: flat through Years 1-5 at 52-58%, then a jump to ~66% in Year 6, in
-- EVERY subject. That pattern is the basis for the year-calibrated-content
-- caveat in docs/SCORING.md.
-- Also: the blank year_group rows total 1,433, matching the orphan count exactly.
select
    c.subject_name,
    s.year_group_at_sitting,
    count(*) as responses,
    round(100 * countif(r.is_correct) / count(*), 1) as percentage_correct
from `atom-analytics-candidates.de_raw.responses` r
join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
group by 1, 2 order by 1, 2;

-- 6.3 Percentage correct by session type and style.
-- Look for: a style whose is_correct does not mean attainment.
-- Found: 3,936 survey rows. Cross-checked in 01 section 5: Wellbeing responses
-- minus orphans (4,032 - 96) equals 3,936 exactly, so survey IS Wellbeing.
select
    s.session_type,
    s.style,
    count(*) as responses,
    round(100 * countif(r.is_correct) / count(*), 1) as percentage_correct
from `atom-analytics-candidates.de_raw.responses` r
join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
group by 1, 2 order by 3 desc;

-- 6.4 No-attempt rate by subject.
-- Look for: a subject where not finishing is normal, which would mean counting
-- no-attempts as wrong is unfair to it.
-- Found: Screeners at 15.7% against ~2% elsewhere - a timed instrument pupils
-- are not expected to complete. Part of the case for not scoring it (D6).
select
    c.subject_name,
    count(*) as responses,
    countif(r.is_no_attempt) as no_attempts,
    round(100 * countif(r.is_no_attempt) / count(*), 1) as pct_no_attempt
from `atom-analytics-candidates.de_raw.responses` r
join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
group by 1 order by pct_no_attempt desc;
