{#
    Where each layer is built.

    By default each layer gets its own dataset: <dataset>_staging, _curated,
    _modelled and _reference. With single_dataset: true, everything is built
    into the target dataset itself - for when only one dataset has been
    provisioned. Model names already carry their layer (stg_, cur_, seed_), so
    nothing collides.
#}

{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if var('single_dataset', false) or custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ target.schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
