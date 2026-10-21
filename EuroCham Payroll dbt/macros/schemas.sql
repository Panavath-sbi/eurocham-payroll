{#- Schema names for the SQL in the models: `{{ app() }}.T_D_PERIOD`, `{{ rpt() }}.V_D_PERIOD`.
    APP = tables + procedures, RPT = views; the uat target gives APP_UAT / RPT_UAT, prod gives APP_PROD / RPT_PROD (same rule as
    generate_schema_name, which places the models). The database is the target's (session database). -#}
{% macro app() -%}{{ generate_schema_name('APP', none) | trim }}{%- endmacro %}
{% macro rpt() -%}{{ generate_schema_name('RPT', none) | trim }}{%- endmacro %}
