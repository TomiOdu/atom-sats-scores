/*
    Round 2 - targeted at what round one surfaced.

    These queries were written to TEST interpretations, not to confirm them.
    Two plausible readings of round one were ruled out this way:

      - Correct answers in zero seconds could be automated. Ruled out in section 7.
      - The session_type mismatch could be corruption. Ruled out in section 1.

    Outputs are in docs/ai/02_profiling_evidence.md.
*/

---------------------------------------------------------------------------
-- 1. Is the session_type mismatch real?
---------------------------------------------------------------------------

-- Hypothesis being tested: responses and sittings disagree because the data is
-- corrupted.
-- Look for: which values pair with which. If the mismatch were corruption, some
-- rows would agree.
-- Found: every one of the 62,274 joinable rows pairs MOCK_TEST with
-- summative_assessment. Both columns are constants in different vocabularies.
-- Neither carries information, so both are dropped (D9).
select
    r.session_type as response_session_type,
    s.session_type as sitting_session_type,
    count(*) as responses
from `atom-analytics-candidates.de_raw.responses` r
join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
group by 1, 2 order by 3 desc;


---------------------------------------------------------------------------
-- 2. Why do 747 sittings have more responses than questions?
---------------------------------------------------------------------------

-- 2.1 Is it repeated questions, or genuinely extra ones?
-- Look for: whether the surplus disappears when you count DISTINCT questions.
-- If it does, the sittings are not longer than intended - the table is emitting
-- rows more than once.
-- Found: all 747 explained by repeats. Zero genuinely extra questions, zero
-- duplicated response_ids.
with per_sitting as (
    select
        r.session_id,
        s.total_questions,
        count(*) as n_rows,
        count(distinct r.question_id) as n_distinct_questions,
        count(distinct r.response_id) as n_distinct_response_ids
    from `atom-analytics-candidates.de_raw.responses` r
    join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
    group by 1, 2
)
select
    countif(n_rows > total_questions) as sittings_over_total,
    countif(n_rows > total_questions and n_distinct_questions <= total_questions)
        as explained_by_repeated_questions,
    countif(n_distinct_questions > total_questions) as genuinely_extra_questions,
    countif(n_rows != n_distinct_response_ids) as duplicate_response_ids
from per_sitting;

-- 2.2 Anatomy of the repeats: are they retries, or the same event emitted twice?
-- Look for: the time gap between copies and whether the outcome changes.
--   A retry would have a LATER timestamp, its own duration, and would plausibly
--   change the outcome. The same event emitted twice would have a gap of zero.
-- Found: the gap is zero at every quartile, for every multiplicity. These are
-- not retries. 2,082 pairs, ~2,411 surplus rows, 965 of which disagree on
-- is_correct - which is why the tie-break had to be arbitrary but deterministic
-- (D3), and why 02_verification.sql measures what it costs.
with pairs as (
    select
        session_id,
        question_id,
        count(*) as n_copies,
        count(distinct response_id) as n_response_ids,
        count(distinct is_correct) as n_distinct_outcomes,
        count(distinct answered_at) as n_distinct_timestamps,
        count(distinct seconds_taken) as n_distinct_durations,
        count(distinct question_number) as n_distinct_question_numbers,
        timestamp_diff(max(answered_at), min(answered_at), second) as gap_seconds
    from `atom-analytics-candidates.de_raw.responses`
    group by 1, 2
    having count(*) > 1
)
select
    n_copies,
    count(*) as pairs,
    countif(n_response_ids < n_copies) as pairs_sharing_a_response_id,
    countif(n_distinct_outcomes > 1) as outcome_changed,
    countif(n_distinct_timestamps > 1) as timestamp_changed,
    countif(n_distinct_durations > 1) as duration_changed,
    countif(n_distinct_question_numbers > 1) as question_number_changed,
    approx_quantiles(gap_seconds, 4) as gap_seconds_quartiles
from pairs
group by 1 order by 1;

-- 2.3 How many surplus rows in total, and how many conflict?
-- Found: 2,411 surplus, 965 conflicting.
select
    count(*) as duplicated_pairs,
    sum(n_copies) - count(*) as surplus_rows,
    countif(n_distinct_outcomes > 1) as conflicting_pairs
from (
    select session_id, question_id, count(*) as n_copies,
           count(distinct is_correct) as n_distinct_outcomes
    from `atom-analytics-candidates.de_raw.responses`
    group by 1, 2 having count(*) > 1
);


---------------------------------------------------------------------------
-- 3. Where did the 1,433 orphan responses come from?
---------------------------------------------------------------------------

-- 3.1 Orphan profile.
-- Hypothesis being tested: they are a load boundary - responses loaded past the
-- cut-off of the sittings extract.
-- Look for: whether the orphans sit at the EDGE of the sittings date window
-- (a load boundary) or INSIDE it (deleted rows), and whether the affected
-- pupils have other sittings.
-- Found: entirely inside the window, 11/11/2025 to 12/06/2026, and all 44
-- pupils have other intact sittings. Sittings were hard-deleted without
-- cascading to responses. So the rows are kept and flagged (D4).
select
    count(*) as orphan_responses,
    count(distinct r.session_id) as unknown_sessions,
    count(distinct r.pupil_id) as pupils_affected,
    min(r.answered_at) as first_orphan,
    max(r.answered_at) as last_orphan,
    (select min(started_at) from `atom-analytics-candidates.de_raw.assessment_sittings`) as first_sitting,
    (select max(started_at) from `atom-analytics-candidates.de_raw.assessment_sittings`) as last_sitting
from `atom-analytics-candidates.de_raw.responses` r
left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
where s.session_id is null;

-- 3.2 Do the affected pupils have intact sittings too?
-- Look for: a pupil whose entire history is orphaned, whose year group would
-- then be unrecoverable.
-- Found: none. Every affected pupil has other sittings, which is what makes the
-- year-group imputation possible.
with orphan_pupils as (
    select distinct r.pupil_id
    from `atom-analytics-candidates.de_raw.responses` r
    left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
    where s.session_id is null
)
select
    count(*) as pupils_with_orphans,
    countif(number_of_sittings = 0) as pupils_with_no_sittings_at_all
from (
    select
        op.pupil_id,
        (select count(*) from `atom-analytics-candidates.de_raw.assessment_sittings` s
         where s.pupil_id = op.pupil_id) as number_of_sittings
    from orphan_pupils op
);

-- 3.3 Which subjects do the orphans fall in?
-- Look for: whether the loss is concentrated in a scored subject.
-- Found: the Wellbeing share (96) is what makes 4,032 - 96 = 3,936 reconcile
-- against the survey count in 00 section 6.3.
select
    c.subject_name,
    count(*) as orphan_responses
from `atom-analytics-candidates.de_raw.responses` r
join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
where s.session_id is null
group by 1 order by 2 desc;


---------------------------------------------------------------------------
-- 4. Are the impossible year groups typos?
---------------------------------------------------------------------------

-- Hypothesis being tested: 11, 14 and 15 are fat-finger entries in otherwise
-- normal pupil histories, and should be corrected or ignored.
-- Look for: whether those pupils ALSO have sane year groups (a typo) or only
-- the odd one (a different kind of row), and whether any responses hang off them.
-- Found: 25 sittings, 5 pupils, dated 02-03/09/2026, with NO responses at all.
-- Each pupil has a single constant odd year group across 5 sittings. Not typos -
-- test data. Excluded (D7), though they are inert for scoring either way.
select
    s.pupil_id,
    count(*) as sittings,
    string_agg(distinct cast(s.year_group_at_sitting as string) order by cast(s.year_group_at_sitting as string)) as year_groups,
    string_agg(distinct s.style order by s.style) as styles,
    min(date(s.started_at)) as first_sitting,
    max(date(s.started_at)) as last_sitting,
    (select count(*) from `atom-analytics-candidates.de_raw.responses` r
     where r.pupil_id = s.pupil_id) as responses_for_pupil
from `atom-analytics-candidates.de_raw.assessment_sittings` s
where s.pupil_id in (
    select distinct pupil_id
    from `atom-analytics-candidates.de_raw.assessment_sittings`
    where year_group_at_sitting not between 1 and 6
)
group by 1 order by 1;


---------------------------------------------------------------------------
-- 5. Is Wellbeing really the survey?
---------------------------------------------------------------------------

-- Look for: an exact reconciliation. If survey rows and Wellbeing rows agree
-- once orphans are accounted for, that is a mechanism, not a coincidence.
-- Found: 3,936 survey rows; 4,032 Wellbeing responses, 96 of them orphaned.
-- 4,032 - 96 = 3,936. Wellbeing is delivered as a survey, so is_correct there
-- encodes a chosen option rather than attainment. Excluded from scoring (D5).
select
    c.subject_name,
    count(*) as responses,
    countif(s.session_id is null) as orphaned,
    countif(s.style = 'survey') as survey_style,
    countif(s.style = 'fixed_question') as fixed_question_style
from `atom-analytics-candidates.de_raw.responses` r
join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
group by 1 order by 2 desc;


---------------------------------------------------------------------------
-- 6. Can English be split into reading and GPS?
---------------------------------------------------------------------------

-- Look for: anything that names a topic. KS2 has SEPARATE papers and SEPARATE
-- conversion tables for reading and for grammar, punctuation and spelling, so
-- splitting English would remove an assumption entirely.
-- Found: topic_id only, no names anywhere in the hierarchy. English has 6
-- topics and Maths 7, but nothing says which is which. Hence A3 / D12: English
-- is mapped to reading, and the cost of that choice is quantified in
-- docs/ai/03_scoring_research.md at about one scaled point.
select
    c.subject_name,
    c.topic_id,
    count(*) as questions,
    count(distinct c.subtopic_id) as subtopics,
    (select count(*) from `atom-analytics-candidates.de_raw.responses` r
     where r.question_id in (
        select question_id from `atom-analytics-candidates.de_raw.course_hierarchy` c2
        where c2.topic_id = c.topic_id)) as responses
from `atom-analytics-candidates.de_raw.course_hierarchy` c
where c.subject_name in ('English', 'Maths')
group by 1, 2 order by 1, 3 desc;


---------------------------------------------------------------------------
-- 7. Are zero-second answers suspicious?
---------------------------------------------------------------------------

-- Hypothesis being tested: answers marked correct in zero seconds are automated.
-- Look for: how zero-second rows split between no-attempts and real attempts,
-- and whether the attempted ones score ABNORMALLY well. Automated answers would score high.
-- Found: 73% are no-attempts. Confirmed and quantified in 02 section 1 - the
-- attempted remainder scores at the normal rate, so this is a timer that failed
-- to record. Nothing excluded (D8).
select
    case
        when seconds_taken is null then 'null'
        when seconds_taken = 0 then '0'
        when seconds_taken <= 2 then '1-2'
        when seconds_taken <= 10 then '3-10'
        when seconds_taken <= 60 then '11-60'
        else '60+'
    end as seconds_bucket,
    count(*) as responses,
    countif(is_no_attempt) as no_attempts,
    round(100 * countif(is_correct) / count(*), 1) as percentage_correct,
    round(100 * countif(is_correct and not is_no_attempt)
          / nullif(countif(not is_no_attempt), 0), 1) as pct_correct_of_attempted
from `atom-analytics-candidates.de_raw.responses`
group by 1 order by 1;


---------------------------------------------------------------------------
-- 8. What are the sittings with no responses?
---------------------------------------------------------------------------

-- Look for: whether the 79 empty sittings are the same cohort as the impossible
-- year groups. If so, one exclusion covers both.
-- Found: all dated August-September 2026, and the only place the 'adaptive' and
-- 'non_adaptive' styles appear. Same cohort (D7).
select
    s.style,
    s.year_group_at_sitting,
    date_trunc(date(s.started_at), month) as started_month,
    count(*) as sittings
from `atom-analytics-candidates.de_raw.assessment_sittings` s
where not exists (
    select 1 from `atom-analytics-candidates.de_raw.responses` r
    where r.session_id = s.session_id
)
group by 1, 2, 3 order by 3, 1;


---------------------------------------------------------------------------
-- 9. Does the daily grain work?
---------------------------------------------------------------------------

-- Look for: whether pupil x subject x day is a sensible size, or so sparse that
-- it is just the response table with extra steps. This is the query that
-- validated the whole store-the-events design before any of it was built.
-- Found: 1,568 rows over 164 pupils and 51 active days, averaging 40.6
-- responses each. A 39x compression that still supports any windowing a
-- colleague later wants.
with deduplicated as (
    select r.*
    from `atom-analytics-candidates.de_raw.responses` r
    qualify row_number() over (
        partition by r.session_id, r.question_id order by r.response_id
    ) = 1
),
daily as (
    select
        d.pupil_id,
        c.subject_id,
        date(d.answered_at) as activity_date,
        count(*) as number_of_responses
    from deduplicated d
    join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
    group by 1, 2, 3
)
select
    count(*) as daily_rows,
    count(distinct pupil_id) as pupils,
    count(distinct activity_date) as active_days,
    round(avg(number_of_responses), 1) as avg_responses_per_row,
    sum(number_of_responses) as total_deduplicated_responses
from daily;
