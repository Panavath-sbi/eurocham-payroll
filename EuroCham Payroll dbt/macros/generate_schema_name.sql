{#- Folder schema as-is (tables/procedures APP, views RPT); the uat and prod targets suffix it (APP_UAT / RPT_UAT,
    APP_PROD / RPT_PROD) so they can share DEV_PAYROLL_DB with dev. -#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%} {{ target.schema }}
    {%- elif target.name in ('uat', 'prod') -%} {{ custom_schema_name | trim }}_{{ target.name | upper }}
    {%- else -%} {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
