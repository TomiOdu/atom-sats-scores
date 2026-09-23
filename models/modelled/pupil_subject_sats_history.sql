{{
    config(
        materialized = 'table',
        partition_by = {'field': 'valid_from', 'data_type': 'date'} if var('partition_models') else none,
        cluster_by = ['pupil_id', 'subject_id']
    )
}}

/*
    One row per pupil, subject and change in their term-to-date SATs score, with
    half-open validity windows (valid_from inclusive, valid_to exclusive). The
    table to migrate into the application database. Point-in-time lookup:

        where valid_from <= @as_of and (valid_to is null or valid_to > @as_of)

    A new row is cut when the score, score_status, is_reliable or paper changes -
    not when evidence merely grows (D23). So every column describes the state as
    at valid_from; exact counts on any date are in cur_pupil_subject_scored.

    No run timestamp: it would make two runs differ, breaking re-runnability (D22).
*/

with end_of_day as (

    -- One row per day (D34). The highest session_id is last in the scoring
    -- window's order, so its term pool includes every sitting that day.
    select *
    from {{ ref('cur_pupil_subject_scored') }}
    qualify row_number() over (
        partition by pupil_id, subject_id, sitting_date
        order by session_id desc
    ) = 1

),

changes_only as (

    select *
    from end_of_day
    -- Keep the first day, then only days where something a consumer sees changed.
    -- IS DISTINCT FROM so that NULL -> NULL is not a change.
    qualify
        lag(sitting_date) over pupil_subject is null
        or lag(term_sats_scaled_score) over pupil_subject is distinct from term_sats_scaled_score
        or lag(score_status) over pupil_subject is distinct from score_status
        or lag(is_reliable) over pupil_subject is distinct from is_reliable
        or lag(paper) over pupil_subject is distinct from paper
    window pupil_subject as (partition by pupil_id, subject_id order by sitting_date)

)

select
    pupil_id,
    subject_id,
    subject_name,

    sitting_date as valid_from,
    lead(sitting_date) over pupil_subject as valid_to,
    lead(sitting_date) over pupil_subject is null as is_current,

    -- The term this score was earned in.
    academic_year,
    term_number_in_year,
    term_name,
    term_label,

    -- The evidence behind the score, as at valid_from.
    number_of_sittings_in_term as number_of_sittings,
    number_of_responses_in_term as number_of_responses,
    number_of_correct_responses_in_term as number_of_correct_responses,
    percentage_correct_in_term as percentage_correct,

    paper,
    conversion_year,
    term_equivalent_raw_mark as equivalent_raw_mark,
    term_sats_scaled_score as sats_scaled_score,

    -- NULL, not FALSE, when unscored: never claim an unscored pupil failed (D24).
    term_sats_scaled_score >= 100 as meets_expected_standard,
    term_sats_scaled_score >= 110 as meets_higher_standard,

    score_status,
    is_reliable,
    sitting_known,
    number_of_responses_all_time,
    year_group,
    year_group_source

from changes_only
window pupil_subject as (partition by pupil_id, subject_id order by sitting_date)
