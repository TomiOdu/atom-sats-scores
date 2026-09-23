{{
    config(
        materialized = 'incremental' if var('partition_models') else 'table',
        incremental_strategy = 'insert_overwrite',
        partition_by = {'field': 'sitting_date', 'data_type': 'date'} if var('partition_models') else none,
        cluster_by = ['pupil_id', 'subject_name'],
        on_schema_change = 'sync_all_columns'
    )
}}

/*
    The event store: questions answered and correct per pupil, subject and
    sitting. Every score is derived from these counts rather than stored (D1).

    The sitting, not the day, because a conversion table scores a paper and a
    sitting is a paper. It is also finer, so daily totals remain derivable (D28).

    INCREMENTAL RUNS rebuild sittings that started inside the lookback window.
    Responses are never answered before their sitting starts, so reading
    responses from the same cutoff gives each of those sittings all its
    responses. Sittings that started earlier are filtered out rather than
    rebuilt from a partial set, which would overwrite their partition with
    incomplete counts.
*/

{% set cutoff = "date_sub(_dbt_max_partition, interval " ~ var('lookback_days') ~ " day)" %}

with per_sitting as (

    select
        pupil_id,
        subject_id,
        subject_name,
        session_id,

        -- The sitting's start date; the first answer where the sitting row is missing.
        coalesce(any_value(sitting_started_date), min(answered_date)) as sitting_date,

        count(*) as number_of_responses,
        -- An unattempted question counts as answered and wrong (D11).
        countif(is_correct) as number_of_correct_responses,
        countif(is_no_attempt) as number_of_questions_not_attempted,

        logical_and(sitting_known) as sitting_known,
        any_value(year_group_at_sitting) as year_group_at_sitting,
        any_value(paper) as paper,
        any_value(scoring_method) as scoring_method

    from {{ ref('cur_responses_enriched') }}
    {% if is_incremental() %}
    where answered_date >= {{ cutoff }}
    {% endif %}
    group by pupil_id, subject_id, subject_name, session_id

),

/*
    Year group for the 56 sittings whose row is missing (D4, D26): the pupil's
    nearest real sitting in time, ties to the earlier one. Reporting only - year
    group is never an input to the score.
*/
imputed_year_groups as (

    select
        p.session_id,
        s.year_group_at_sitting as imputed_year_group
    from per_sitting p
    inner join {{ ref('stg_assessment_sittings') }} s
        on p.pupil_id = s.pupil_id
        and s.has_plausible_year_group
    where not p.sitting_known
    qualify row_number() over (
        partition by p.pupil_id, p.subject_id, p.session_id
        order by abs(date_diff(p.sitting_date, s.started_date, day)), s.started_date, s.session_id
    ) = 1

)

select
    p.pupil_id,
    p.subject_id,
    p.subject_name,
    p.session_id,
    p.sitting_date,

    -- Terms are defined once, in macros/academic_calendar.sql.
    {{ academic_year('p.sitting_date') }} as academic_year,
    {{ term_number_in_year('p.sitting_date') }} as term_number_in_year,
    {{ term_name('p.sitting_date') }} as term_name,
    {{ term_label('p.sitting_date') }} as term_label,

    p.number_of_responses,
    p.number_of_correct_responses,
    p.number_of_questions_not_attempted,
    p.sitting_known,

    coalesce(p.year_group_at_sitting, i.imputed_year_group) as year_group,
    case
        when p.year_group_at_sitting is not null then 'sitting'
        when i.imputed_year_group is not null then 'imputed_nearest'
        else 'unknown'
    end as year_group_source,

    p.paper,
    p.scoring_method

from per_sitting p
left join imputed_year_groups i
    on p.session_id = i.session_id
{% if is_incremental() %}
where p.sitting_date >= {{ cutoff }}
{% endif %}
