/*
    One row per sitting.

    QA sittings are flagged here and filtered in curated, because deciding what
    counts as evidence is a business rule. is_test_sitting marks the 25
    September 2026 sittings with year groups 11, 14 or 15: no responses, and the
    only place the 'adaptive' / 'non_adaptive' styles appear (D7).

    session_type is dropped: a constant (D9). total_questions is kept for
    reference but never used as a denominator - it is wrong for 756 sittings (D10).
*/

select
    session_id,
    pupil_id,
    assessment_id,
    style,
    year_group_at_sitting,
    year_group_at_sitting between 1 and 6 as has_plausible_year_group,
    total_questions,
    is_complete,
    started_at,
    finished_at,
    date(started_at) as started_date,
    style in ('adaptive', 'non_adaptive')
        or not (year_group_at_sitting between 1 and 6) as is_test_sitting

from {{ source('de_raw', 'assessment_sittings') }}

-- Matches nothing today; kept for production (D19).
where coalesce(is_deleted, false) = false
