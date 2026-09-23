/*
    The headline score pools questions from the start of the pupil's current
    term. If the window frame in cur_pupil_subject_scored ever loses part of its
    partition key - a plausible edit, since that frame is the one line a
    colleague is explicitly invited to change - the pool would silently run on
    across term boundaries and every score would quietly become a longer
    average.

    Nothing else would fail. The scores would still be in range, still carry a
    status, still be monotonic in evidence. The bug would show only as scores
    that move less than they should, which nobody would notice for months.

    The property that catches it: the FIRST sitting of any term must be pooled
    from that sitting alone.
*/

with first_sitting_of_term as (

    select
        pupil_id,
        subject_id,
        academic_year,
        term_number_in_year,
        session_id,
        sitting_date,
        number_of_responses_in_sitting,
        number_of_responses_in_term,
        number_of_sittings_in_term,
        row_number() over (
            partition by pupil_id, subject_id, academic_year, term_number_in_year
            order by sitting_date, session_id
        ) as sitting_rank_in_term
    from {{ ref('cur_pupil_subject_scored') }}

)

select *
from first_sitting_of_term
where sitting_rank_in_term = 1
  and (number_of_responses_in_term != number_of_responses_in_sitting or number_of_sittings_in_term != 1)
