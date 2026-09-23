{{
    config(
        materialized = 'incremental' if var('partition_models') else 'table',
        incremental_strategy = 'insert_overwrite',
        partition_by = {'field': 'answered_date', 'data_type': 'date'} if var('partition_models') else none,
        cluster_by = ['pupil_id', 'session_id'],
        on_schema_change = 'sync_all_columns'
    )
}}

/*
    One row per answer, deduplicated.

    The source emits 2,082 (session_id, question_id) pairs 2-5 times, and 965 of
    them disagree on is_correct. The copies share an identical answered_at, so
    there is no "latest" to prefer: the lowest response_id wins. response_id is a
    random UUID, so this is deterministic and effectively a random pick - no bias
    towards right or wrong answers (D3, README section 5).

    A partitioned table rather than a view because responses will pass 100m rows.
    Deduplicating one day at a time is safe because every copy of an event
    carries the same answered_at, so all copies land in the same partition.
    Incremental runs rebuild the last lookback_days partitions whole.
*/

with source as (

    select
        response_id,
        pupil_id,
        session_id,
        question_id,
        is_correct,
        is_no_attempt,
        seconds_taken,
        question_number,
        answered_at
    from {{ source('de_raw', 'responses') }}

    {% if is_incremental() %}
    -- _dbt_max_partition is declared by dbt's insert_overwrite strategy.
    where date(answered_at) >= date_sub(_dbt_max_partition, interval {{ var('lookback_days') }} day)
    {% endif %}

)

select
    response_id,
    pupil_id,
    session_id,
    question_id,

    -- NULL is treated as not correct, consistent with a blank scoring zero (D11).
    coalesce(is_correct, false) as is_correct,
    coalesce(is_no_attempt, false) as is_no_attempt,

    seconds_taken,
    question_number as question_number_in_sitting,
    answered_at,
    date(answered_at) as answered_date,

    -- Kept so the duplicate problem stays visible rather than silently resolved.
    count(*) over (partition by session_id, question_id) as number_of_source_emissions

from source
qualify row_number() over (partition by session_id, question_id order by response_id) = 1
