{{ config(materialized = 'view') }}

/*
    One deduplicated response with its subject, sitting details and scoring
    method.

    A view: it is only a join, and its one consumer (cur_pupil_subject_sitting)
    filters it by answered_date on incremental runs. As a view that filter
    reaches stg_responses' partitions directly; as a table this would be a full
    rebuild of 100m+ rows on every run.

    Subject comes from the question, not the sitting. Unscored subjects are kept
    and labelled with their scoring_method. The only rows removed are QA test
    sittings (D7). Responses whose sitting row is missing are kept with
    sitting_known = FALSE (D4).
*/

select
    r.response_id,
    r.pupil_id,
    r.session_id,
    r.question_id,
    h.subject_id,
    h.subject_name,
    h.topic_id,
    r.is_correct,
    r.is_no_attempt,
    r.seconds_taken,
    r.answered_at,
    r.answered_date,

    s.session_id is not null as sitting_known,
    s.started_date as sitting_started_date,
    s.year_group_at_sitting,

    m.paper,
    m.scoring_method

from {{ ref('stg_responses') }} r
left join {{ ref('stg_assessment_sittings') }} s
    on r.session_id = s.session_id
-- Inner join is safe: a relationships test fails the build if a question is missing.
inner join {{ ref('stg_course_hierarchy') }} h
    on r.question_id = h.question_id
left join {{ ref('seed_subject_mapping') }} m
    on h.subject_name = m.subject_name

where coalesce(s.is_test_sitting, false) = false
