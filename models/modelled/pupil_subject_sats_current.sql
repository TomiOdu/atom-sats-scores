{{ config(materialized = 'view') }}

/*
    Every pupil in every subject, with their score as it stands today. What a
    dashboard or the application reads by default.

    The brief asks for a score for every pupil in every subject, so this starts
    from pupils x subjects rather than from activity. A pupil with no responses
    in a subject still gets a row, with a NULL score and score_status =
    'no_responses'. A missing row looks like a bug; a NULL with a reason does not.

    Same columns as the history table, so the two can share DDL when they
    migrate. Rows with no evidence have no validity window, so valid_from is NULL.
*/

with pupil_subjects as (

    select
        p.pupil_id,
        s.subject_id,
        s.subject_name
    from {{ ref('stg_pupils') }} p
    cross join (
        select distinct subject_id, subject_name
        from {{ ref('stg_course_hierarchy') }}
    ) s

),

latest as (

    select *
    from {{ ref('pupil_subject_sats_history') }}
    where is_current

)

select
    ps.pupil_id,
    ps.subject_id,
    ps.subject_name,

    l.valid_from,
    l.valid_to,
    true as is_current,

    l.academic_year,
    l.term_number_in_year,
    l.term_name,
    l.term_label,

    coalesce(l.number_of_sittings, 0) as number_of_sittings,
    coalesce(l.number_of_responses, 0) as number_of_responses,
    coalesce(l.number_of_correct_responses, 0) as number_of_correct_responses,
    l.percentage_correct,

    l.paper,
    {{ var('conversion_year') }} as conversion_year,
    l.equivalent_raw_mark,
    l.sats_scaled_score,
    l.meets_expected_standard,
    l.meets_higher_standard,

    coalesce(l.score_status, 'no_responses') as score_status,
    coalesce(l.is_reliable, false) as is_reliable,
    l.sitting_known,
    coalesce(l.number_of_responses_all_time, 0) as number_of_responses_all_time,
    l.year_group,
    coalesce(l.year_group_source, 'unknown') as year_group_source

from pupil_subjects ps
left join latest l
    on ps.pupil_id = l.pupil_id
    and ps.subject_id = l.subject_id
