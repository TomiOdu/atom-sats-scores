/*
    Point-in-time correctness depends entirely on the validity windows being
    well formed. Two failures would be invisible in a spot check and fatal in a
    dashboard: a gap, where an as-at query returns no row for a date the pupil
    was active, and an overlap, where it returns two.

    Each version's valid_to must equal the next version's valid_from exactly,
    and only the last version may be open.
*/

with ordered as (

    select
        pupil_id,
        subject_id,
        valid_from,
        valid_to,
        lead(valid_from) over (
            partition by pupil_id, subject_id
            order by valid_from
        ) as next_valid_from
    from {{ ref('pupil_subject_sats_history') }}

)

select *
from ordered
where
    -- A closed window that does not meet the next one: a gap or an overlap.
    (next_valid_from is not null and valid_to != next_valid_from)
    -- An open window with a version after it.
    or (valid_to is null and next_valid_from is not null)
    -- A closed window with nothing after it: the series must end open.
    or (valid_to is not null and next_valid_from is null)
