{#- Folder schema as-is (tables/procedures APP, views RPT); no suffix on any target: APP / RPT. Environments are told apart by the target's database. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%} {{ target.schema }}
    {%- else -%} {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
