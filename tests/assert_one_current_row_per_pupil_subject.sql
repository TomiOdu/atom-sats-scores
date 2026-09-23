/*
    The application reads pupil_subject_sats_current expecting one row per pupil
    per subject. Zero rows would hide a pupil; two would double-count them on
    any dashboard that aggregates.
*/

select
    pupil_id,
    subject_id,
    count(*) as n_current_rows
from {{ ref('pupil_subject_sats_history') }}
where is_current
group by 1, 2
having count(*) != 1
