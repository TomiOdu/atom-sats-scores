/*
    The sitting model is the only place the response grain is collapsed, so it
    is the only place rows can be lost or duplicated without anything else
    noticing. Every response in cur_responses_enriched must be counted exactly
    once in cur_pupil_subject_sitting.
*/

with from_responses as (

    select
        pupil_id,
        subject_id,
        session_id,
        count(*) as n_expected,
        countif(is_correct) as n_correct_expected
    from {{ ref('cur_responses_enriched') }}
    group by 1, 2, 3

),

from_sittings as (

    select
        pupil_id,
        subject_id,
        session_id,
        number_of_responses,
        number_of_correct_responses
    from {{ ref('cur_pupil_subject_sitting') }}

)

select
    coalesce(r.pupil_id, s.pupil_id) as pupil_id,
    coalesce(r.subject_id, s.subject_id) as subject_id,
    coalesce(r.session_id, s.session_id) as session_id,
    r.n_expected,
    s.number_of_responses,
    r.n_correct_expected,
    s.number_of_correct_responses
from from_responses r
full outer join from_sittings s
    on r.pupil_id = s.pupil_id
    and r.subject_id = s.subject_id
    and r.session_id = s.session_id
where r.n_expected is distinct from s.number_of_responses
   or r.n_correct_expected is distinct from s.number_of_correct_responses
