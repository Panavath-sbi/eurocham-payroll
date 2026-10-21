{#- Runs the model's own SQL as-is (CREATE TABLE IF NOT EXISTS T_x ...; reference rows):
    never drops or replaces, so table data is safe on every run.
    ponytail: column changes = ALTER TABLE T_x ADD COLUMN IF NOT EXISTS ... in the same model.
    ponytail: also deploys the procedures (models/procedures/: CREATE OR REPLACE PROCEDURE SP_x ... COPY GRANTS);
    views (models/views/) too; dbt lists all of them as tables, which only affects docs. -#}
{% materialization ddl_table, adapter='snowflake' %}
  {{ run_hooks(pre_hooks) }}
  {% call statement('main') %}{{ sql }}{% endcall %}
  {{ run_hooks(post_hooks) }}
  {{ return({'relations': [this.incorporate(type='table')]}) }}
{% endmaterialization %}
