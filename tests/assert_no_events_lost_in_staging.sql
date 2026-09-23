/*
    stg_responses must contain exactly one row for every distinct
    (session_id, question_id) in the source. Nothing may go missing.

    WHY THIS EXISTS, AND WHY IT IS NOT PARANOIA
    The first real build of this project ran into a BigQuery sandbox, which
    silently enforces a 60-day partition expiry. The source spans ten months, so
    97% of the rows were deleted the moment they were written - 61,296 became
    1,503 - and the build reported success.

    Every other test still passed. Not one of them was wrong to: they check
    uniqueness, ranges, referential integrity and internal consistency, and a
    truncated table is perfectly consistent with itself. Nothing in the suite
    asserted that the data was all still there.

    That is the gap this closes. It is a reconciliation against the source rather
    than a hardcoded row count, so it does not need updating as the data grows,
    and it fails loudly on anything that removes rows without removing them
    upstream too: a partition expiry, a botched incremental filter, a lookback
    window that is too short, a WHERE clause that was meant to be temporary.
*/

with source_events as (

    select count(distinct concat(cast(session_id as string), '|', cast(question_id as string)))
        as n_expected
    from {{ source('de_raw', 'responses') }}

),

staged as (

    select count(*) as n_actual
    from {{ ref('stg_responses') }}

)

select
    s.n_expected,
    a.n_actual,
    s.n_expected - a.n_actual as n_missing
from source_events s
cross join staged a
where s.n_expected != a.n_actual
