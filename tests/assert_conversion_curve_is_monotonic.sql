/*
    An extra mark must never produce a lower scaled score. This is a property of
    the published tables, but the seed is the thing that could be typed or
    regenerated wrongly, and a non-monotonic curve would make a pupil's score
    fall after a good day - the single most damaging bug this pipeline could
    ship to a teacher.
*/

with ordered as (

    select
        paper,
        conversion_year,
        raw_mark,
        scaled_score,
        lag(scaled_score) over (
            partition by paper, conversion_year
            order by raw_mark
        ) as previous_scaled_score
    from {{ ref('seed_sats_conversion') }}
    where scaled_score is not null

)

select *
from ordered
where previous_scaled_score is not null
  and scaled_score < previous_scaled_score
