/*
    One row per question, placing it in the subject hierarchy. A catalogue, not
    an activity log: 672 questions have no responses.

    atom_id and subtopic_id are unused today but kept, so topic-level work is an
    addition to curated rather than a change to staging.
*/

select
    question_id,
    atom_id,
    subtopic_id,
    topic_id,
    subject_id,
    subject_name

from {{ source('de_raw', 'course_hierarchy') }}
