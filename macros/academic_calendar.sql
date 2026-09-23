{#
    The English school calendar, defined once.

    Term is the reporting unit the whole model now hangs off, so it must mean
    exactly one thing. These macros are the only place it is defined; every
    model calls them rather than re-deriving the arithmetic.

    DEFINITION, AND ITS LIMITS
    Real term dates vary by school and local authority, and the spring/summer
    boundary moves with Easter. Nothing in this dataset says when any school's
    terms actually ran, so the calendar below is a deterministic approximation
    on calendar-month boundaries:

        autumn  September - December   (term_number_in_year 1)
        spring  January - March        (term_number_in_year 2)
        summer  April - August         (term_number_in_year 3)

    August is folded into the summer term so that every date belongs to exactly
    one term and no activity falls into a gap. A pupil answering questions over
    the summer holiday is counted against the term that just ended, which is the
    less surprising of the two options.

    If Atom holds real term dates, they should become a seed keyed on school and
    academic year, and these macros should read it. That is question 8 in
    docs/SCORING.md section 5.
#}

{% macro academic_year(date_expr) -%}
    (extract(year from {{ date_expr }}) - if(extract(month from {{ date_expr }}) < 9, 1, 0))
{%- endmacro %}


{% macro term_number_in_year(date_expr) -%}
    (case
        when extract(month from {{ date_expr }}) between 9 and 12 then 1
        when extract(month from {{ date_expr }}) between 1 and 3 then 2
        else 3
    end)
{%- endmacro %}


{% macro term_name(date_expr) -%}
    (case
        when extract(month from {{ date_expr }}) between 9 and 12 then 'autumn'
        when extract(month from {{ date_expr }}) between 1 and 3 then 'spring'
        else 'summer'
    end)
{%- endmacro %}


{#
    A single sortable, human-readable label: 'Autumn 2025/26'.
    Sorting is done on (academic_year, term_number_in_year), never on this string.
#}
{% macro term_label(date_expr) -%}
    concat(
        initcap({{ term_name(date_expr) }}), ' ',
        cast({{ academic_year(date_expr) }} as string), '/',
        substr(cast({{ academic_year(date_expr) }} + 1 as string), 3, 2)
    )
{%- endmacro %}
