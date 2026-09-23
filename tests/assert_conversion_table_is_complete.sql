/*
    score_status = 'no_conversion_available' should be unreachable: it exists so
    that a missing lookup surfaces as a stated reason rather than an unexplained
    NULL. This test makes sure it stays unreachable, by checking the seed covers
    every raw mark from 0 to the paper maximum for the configured year.

    A seed refreshed for a new year with a truncated table is the realistic way
    this breaks, and it would otherwise show up as a handful of pupils quietly
    losing their scores.
*/

with expected as (

    select
        p.paper,
        p.conversion_year,
        raw_mark
    from {{ ref('seed_sats_paper') }} p,
        unnest(generate_array(0, p.max_raw_mark)) as raw_mark
    where p.conversion_year = {{ var('conversion_year') }}

),

actual as (

    select paper, conversion_year, raw_mark
    from {{ ref('seed_sats_conversion') }}
    where conversion_year = {{ var('conversion_year') }}

)

select e.*
from expected e
left join actual a
    on e.paper = a.paper
    and e.conversion_year = a.conversion_year
    and e.raw_mark = a.raw_mark
where a.raw_mark is null
