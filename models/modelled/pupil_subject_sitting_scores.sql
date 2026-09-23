{{
    config(
        materialized = 'table',
        partition_by = {'field': 'sitting_date', 'data_type': 'date'} if var('partition_models') else none,
        cluster_by = ['pupil_id', 'subject_id']
    )
}}

/*
    One row per sitting: what the pupil scored on that test, that day.

    This is the trajectory. pupil_subject_sats_history answers "what is this
    pupil's score, and when did it change"; this answers "how did they do each
    time they sat something", which is the series a progress chart plots.

    Kept separate rather than folded into the history table because the two have
    different grains and different jobs. Every row here is an event that
    happened; a row in the history table is a period during which something was
    true.

    A caution worth repeating wherever this is consumed: a single sitting is
    around 25 questions, so its score carries roughly +/-3 scaled points of
    sampling noise. Movement between two consecutive sittings is usually noise.
    The line is meaningful; the individual points are not. That is the whole
    reason the headline score pools a term.
*/

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

    number_of_responses_in_sitting as number_of_responses,
    number_of_correct_responses_in_sitting as number_of_correct_responses,
    percentage_correct_in_sitting as percentage_correct,
    sitting_equivalent_raw_mark as equivalent_raw_mark,
    sitting_sats_scaled_score as sats_scaled_score,

    -- The term-to-date score as it stood immediately after this sitting, so a
    -- chart can plot the smoothed line against the raw points without a join.
    term_sats_scaled_score,
    number_of_responses_in_term,

    paper,
    conversion_year,
    score_status,
    is_reliable,
    sitting_known,

    year_group,
    year_group_source

from {{ ref('cur_pupil_subject_scored') }}
