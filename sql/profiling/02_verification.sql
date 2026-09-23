/*
    Round 3 - settling the two decisions that were still arguable.

    The point of this file is that neither question is answered by assertion.
    Section 1 tests whether zero-second answers should be excluded by checking
    whether they behave differently from anything else. Section 2 does not argue
    that the dedupe tie-break is right; it MEASURES what choosing wrongly would
    cost, by scoring every pupil three ways. That number - 1.8pp on average for
    the scored subjects - is what turned an open assumption into a quantified
    risk, and it is quoted in README section 5.

    Outputs are in docs/ai/02_profiling_evidence.md.
*/

---------------------------------------------------------------------------
-- 1. Confirm the zero-second explanation
---------------------------------------------------------------------------

-- The test: if zero-second answers were automated, the attempted ones would
-- score noticeably ABOVE the baseline, and some would be marked correct despite
-- being flagged as no-attempts.
-- Found: 58.9% against a 59.8% baseline - marginally below, not above - and
-- zero contradictions. A timer that failed to record. Kept (D8).
select
    countif(is_no_attempt and is_correct) as contradictions_no_attempt_but_correct,
    countif(is_no_attempt and not is_correct) as no_attempts_marked_wrong,
    countif(is_no_attempt and seconds_taken = 0) as no_attempts_at_zero_seconds,
    countif(not is_no_attempt and seconds_taken = 0) as attempted_at_zero_seconds,
    round(100 * countif(not is_no_attempt and seconds_taken = 0 and is_correct)
          / nullif(countif(not is_no_attempt and seconds_taken = 0), 0), 1)
        as pct_correct_attempted_at_zero_seconds,
    round(100 * countif(not is_no_attempt and seconds_taken > 10 and is_correct)
          / nullif(countif(not is_no_attempt and seconds_taken > 10), 0), 1)
        as pct_correct_baseline_over_10s
from `atom-analytics-candidates.de_raw.responses`;


---------------------------------------------------------------------------
-- 2. What does the dedupe tie-break cost?
---------------------------------------------------------------------------

/*
    Every duplicated (session, question) pair is resolved three ways, and each
    pupil scored three times:

      optimistic    - correct if ANY copy says correct
      pessimistic   - correct only if ALL copies say correct
      deterministic - the copy with the lowest response_id (what the model does)

    The spread between optimistic and pessimistic is the whole range of
    defensible answers. Where that range is narrow, the choice barely matters.

    Note that optimistic and pessimistic are not "safer" alternatives: each
    biases every affected pupil in the SAME direction, systematically inflating
    or deflating the cohort. An arbitrary but unbiased rule is preferable to a
    consistently wrong one - which is the argument for D3.

    Found:
      English            141 of 154 affected, mean spread 1.79pp, worst 5.52pp
      Maths              136 of 152 affected, mean spread 1.75pp, worst 8.06pp
      Verbal Reasoning     5 of   8 affected, mean spread 15.79pp, worst 30.26pp

    Verbal Reasoning shows the mechanism: those pupils have only 36-119
    responses, so each duplicate carries far more weight. That is the empirical
    basis for the reliability flag (D17) - a threshold derived from observed
    sensitivity rather than picked out of the air.
*/
with resolved as (

    select
        r.pupil_id,
        c.subject_name,
        r.session_id,
        r.question_id,
        count(*) as n_copies,
        logical_or(r.is_correct) as optimistic,
        logical_and(r.is_correct) as pessimistic,
        -- The model's rule: lowest response_id wins.
        any_value(r.is_correct having min r.response_id) as deterministic
    from `atom-analytics-candidates.de_raw.responses` r
    join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
    group by 1, 2, 3, 4

),

per_pupil_subject as (

    select
        pupil_id,
        subject_name,
        count(*) as n_questions,
        countif(n_copies > 1) as n_duplicated,
        round(100 * countif(optimistic) / count(*), 2) as pct_optimistic,
        round(100 * countif(pessimistic) / count(*), 2) as pct_pessimistic,
        round(100 * countif(deterministic) / count(*), 2) as pct_deterministic
    from resolved
    group by 1, 2

)

select
    subject_name,
    count(*) as pupil_subjects,
    countif(n_duplicated > 0) as affected,
    round(avg(if(n_duplicated > 0, pct_optimistic - pct_pessimistic, null)), 2) as mean_spread_pp,
    round(max(pct_optimistic - pct_pessimistic), 2) as worst_spread_pp,
    -- How far the model's actual choice sits from the middle of the range.
    round(avg(pct_deterministic - (pct_optimistic + pct_pessimistic) / 2), 2) as mean_bias_pp
from per_pupil_subject
group by 1 order by affected desc;


---------------------------------------------------------------------------
-- 3. Can year group be imputed for the orphaned responses?
---------------------------------------------------------------------------

-- The question: 1,433 responses have no sitting, so no year group. Year group
-- is a reporting dimension rather than an input to the score, so an unresolved
-- value degrades the breakdown, not the number - but it is worth recovering if
-- it is unambiguous.
-- Look for: whether each affected pupil has ONE year group per academic year.
-- If so, the imputation is a lookup rather than a guess.
-- Found: 44 pupils, 38 unambiguous within an academic year. The remaining 6 are
-- resolved by nearest sitting in time, ties going to the earlier one (D4).
with orphan_pupil_days as (

    select distinct
        r.pupil_id,
        date(r.answered_at) as answered_date,
        extract(year from r.answered_at)
            - if(extract(month from r.answered_at) < 9, 1, 0) as academic_year
    from `atom-analytics-candidates.de_raw.responses` r
    left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
    where s.session_id is null

),

sittings as (

    select
        pupil_id,
        session_id,
        date(started_at) as started_date,
        year_group_at_sitting,
        extract(year from started_at)
            - if(extract(month from started_at) < 9, 1, 0) as academic_year
    from `atom-analytics-candidates.de_raw.assessment_sittings`
    where year_group_at_sitting between 1 and 6

),

ambiguity as (

    select
        o.pupil_id,
        o.academic_year,
        count(distinct s.year_group_at_sitting) as distinct_year_groups_in_year
    from orphan_pupil_days o
    left join sittings s
        on o.pupil_id = s.pupil_id
        and o.academic_year = s.academic_year
    group by 1, 2

)

select
    count(distinct pupil_id) as pupils_needing_imputation,
    countif(distinct_year_groups_in_year = 1) as unambiguous_pupil_years,
    countif(distinct_year_groups_in_year > 1) as ambiguous_pupil_years,
    countif(distinct_year_groups_in_year = 0) as no_sitting_in_that_academic_year
from ambiguity;


-- 3.1 The nearest-sitting rule, run over the real orphans so the result could be
-- checked before it was built into the model. The model applies the same rule
-- per missing sitting (D26), which gives the same year groups.
with orphan_pupil_days as (
    select distinct r.pupil_id, date(r.answered_at) as answered_date
    from `atom-analytics-candidates.de_raw.responses` r
    left join `atom-analytics-candidates.de_raw.assessment_sittings` s using (session_id)
    where s.session_id is null
),
sittings as (
    select pupil_id, session_id, date(started_at) as started_date, year_group_at_sitting
    from `atom-analytics-candidates.de_raw.assessment_sittings`
    where year_group_at_sitting between 1 and 6
)
select
    o.pupil_id,
    o.answered_date,
    s.year_group_at_sitting as imputed_year_group,
    abs(date_diff(o.answered_date, s.started_date, day)) as days_from_nearest_sitting
from orphan_pupil_days o
join sittings s on o.pupil_id = s.pupil_id
qualify row_number() over (
    partition by o.pupil_id, o.answered_date
    order by
        abs(date_diff(o.answered_date, s.started_date, day)) asc,
        s.started_date asc,
        s.session_id asc
) = 1
order by days_from_nearest_sitting desc
limit 50;


---------------------------------------------------------------------------
-- 4. What will the output actually look like?
---------------------------------------------------------------------------

-- Run before building anything, so the expected shape was on record BEFORE the
-- models produced it. A narrow band slightly above 100 is the prediction; if
-- the built model disagrees, the model is wrong.
-- Found: cohort percentages of ~58% (English) and ~57.7% (Maths) put the
-- typical pupil at 101-103, and Year 6 at ~66% around 103-105.
with deduplicated as (
    select r.*
    from `atom-analytics-candidates.de_raw.responses` r
    qualify row_number() over (
        partition by r.session_id, r.question_id order by r.response_id
    ) = 1
)
select
    c.subject_name,
    count(distinct d.pupil_id) as pupils,
    count(*) as responses,
    round(100 * countif(d.is_correct) / count(*), 2) as percentage_correct
from deduplicated d
join `atom-analytics-candidates.de_raw.course_hierarchy` c using (question_id)
group by 1 order by pupils desc;
