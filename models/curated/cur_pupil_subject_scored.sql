{{
    config(
        materialized = 'table',
        partition_by = {'field': 'sitting_date', 'data_type': 'date'} if var('partition_models') else none,
        cluster_by = ['pupil_id', 'subject_name']
    )
}}

/*
    Two scores for every sitting. THE ONLY MODEL THAT KNOWS HOW A SCORE IS
    CALCULATED - change the rule here and nowhere else.

    sitting_sats_scaled_score   This sitting alone. Noisy (~25 questions,
                                ~±3.5 scaled points), but it is the trajectory.
    term_sats_scaled_score      Every question in this subject so far this term,
                                pooled. The headline score (D29).

    The term pool sums questions rather than averaging sitting percentages, so
    bigger sittings count for more (D30). It runs from the start of term to the
    sitting in hand, so its value on any past date is exactly what it was then
    (D31). It resets each term, and is_reliable drops when it does.

    Method: percentage correct x paper max = equivalent raw mark, then look it up
    in the GOV.UK conversion table. That treats 58% on Atom as 58% of the SATs
    paper's marks - the weakest assumption (A5, docs/SCORING.md section 1).

    A full rebuild: a term-to-date total spans partitions, so it cannot be
    rebuilt one partition at a time.
*/

with pooled as (

    select
        *,
        -- The scoring window. To score on a different window, change this frame only.
        sum(number_of_responses) over term_window as number_of_responses_in_term,
        sum(number_of_correct_responses) over term_window as number_of_correct_responses_in_term,
        count(*) over term_window as number_of_sittings_in_term,
        logical_and(sitting_known) over term_window as sitting_known_in_term,
        sum(number_of_responses) over (
            partition by pupil_id, subject_id
            order by sitting_date, session_id
        ) as number_of_responses_all_time
    from {{ ref('cur_pupil_subject_sitting') }}
    window term_window as (
        partition by pupil_id, subject_id, academic_year, term_number_in_year
        order by sitting_date, session_id
        rows between unbounded preceding and current row
    )

),

with_raw_marks as (

    select
        pooled.*,
        paper.min_raw_mark_for_score,
        cast(round(number_of_correct_responses / number_of_responses * paper.max_raw_mark) as int64)
            as sitting_equivalent_raw_mark,
        cast(round(number_of_correct_responses_in_term / number_of_responses_in_term * paper.max_raw_mark) as int64)
            as term_equivalent_raw_mark
    from pooled
    left join {{ ref('seed_sats_paper') }} paper
        on pooled.paper = paper.paper
        and paper.conversion_year = {{ var('conversion_year') }}

),

scored as (

    select
        r.*,
        sitting_lookup.scaled_score as sitting_lookup_score,
        term_lookup.scaled_score as term_lookup_score
    from with_raw_marks r
    left join {{ ref('seed_sats_conversion') }} sitting_lookup
        on r.paper = sitting_lookup.paper
        and r.sitting_equivalent_raw_mark = sitting_lookup.raw_mark
        and sitting_lookup.conversion_year = {{ var('conversion_year') }}
    left join {{ ref('seed_sats_conversion') }} term_lookup
        on r.paper = term_lookup.paper
        and r.term_equivalent_raw_mark = term_lookup.raw_mark
        and term_lookup.conversion_year = {{ var('conversion_year') }}

)

select
    pupil_id,
    subject_id,
    subject_name,
    session_id,
    sitting_date,
    academic_year,
    term_number_in_year,
    term_name,
    term_label,

    -- This sitting alone.
    number_of_responses as number_of_responses_in_sitting,
    number_of_correct_responses as number_of_correct_responses_in_sitting,
    round(number_of_correct_responses / number_of_responses * 100, 2) as percentage_correct_in_sitting,
    sitting_equivalent_raw_mark,
    -- A score needs a scored subject and at least 3 raw marks. Clamped to the
    -- published 80-120 range in case the seed is ever replaced with a bad one.
    case
        when scoring_method = 'sats_conversion' and sitting_equivalent_raw_mark >= min_raw_mark_for_score
            then least(greatest(sitting_lookup_score, 80), 120)
    end as sitting_sats_scaled_score,

    -- Term to date: the headline.
    number_of_sittings_in_term,
    number_of_responses_in_term,
    number_of_correct_responses_in_term,
    round(number_of_correct_responses_in_term / number_of_responses_in_term * 100, 2) as percentage_correct_in_term,
    term_equivalent_raw_mark,
    case
        when scoring_method = 'sats_conversion' and term_equivalent_raw_mark >= min_raw_mark_for_score
            then least(greatest(term_lookup_score, 80), 120)
    end as term_sats_scaled_score,

    paper,
    {{ var('conversion_year') }} as conversion_year,

    -- Why the term score is or is not present. Never NULL.
    case
        when scoring_method is null then 'unmapped_subject'
        when scoring_method != 'sats_conversion' then scoring_method  -- 'excluded' or 'not_applicable'
        when term_equivalent_raw_mark < min_raw_mark_for_score then 'below_minimum_raw_score'
        when term_lookup_score is null then 'no_conversion_available'
        else 'sats_conversion'
    end as score_status,

    -- Flags, never filters (D17). Measures the term's evidence.
    number_of_responses_in_term >= {{ var('min_responses') }} as is_reliable,
    sitting_known_in_term as sitting_known,

    number_of_responses_all_time,
    year_group,
    year_group_source

from scored
