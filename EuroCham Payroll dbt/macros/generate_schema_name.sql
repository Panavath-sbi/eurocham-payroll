{#- Folder schema as-is (tables/procedures APP, views RPT); the uat target suffixes it (APP_UAT, RPT_UAT)
    so UAT can share DEV_PAYROLL_DB with dev. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%} {{ target.schema }}
    {%- elif target.name == 'uat' -%} {{ custom_schema_name | trim }}_UAT
    {%- else -%} {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
