/*
    One row per pupil. 242 rows, of which 164 have responses. Every pupil appears
    in pupil_subject_sats_current, including those with no activity.
*/

select
    pupil_id

from {{ source('de_raw', 'pupils') }}

-- Matches nothing today; kept for production (D19).
where coalesce(is_deleted, false) = false
