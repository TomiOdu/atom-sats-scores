/*
    The brief asks for a score for every pupil in every subject. The current view
    must therefore hold exactly one row per pupil x subject - no pupil missing
    because they have no activity, and no subject missing because nobody has
    sat it yet (Science).
*/

select count(*) as n_rows
from {{ ref('pupil_subject_sats_current') }}
having count(*) != (
    (select count(*) from {{ ref('stg_pupils') }})
    * (select count(distinct subject_id) from {{ ref('stg_course_hierarchy') }})
)
