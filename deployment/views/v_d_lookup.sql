-- depends_on: T_D_ENTITY, T_D_FUND, T_D_DEPARTMENT
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_D_LOOKUP - dropdown lists in one read: entities (chambers), funds, departments
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version (in R__views_rpt_app.sql).
   2026-10-19  Own file for DLSync: names qualified with ${DB}, COPY GRANTS keeps the app's
               SELECT grant when the view is replaced.

   Read by the app (LoadSession -> colLookups).
   ===================================================================================== */
CREATE OR REPLACE VIEW {{ schema_rpt }}.V_D_LOOKUP (
    LOOKUP_TYPE COMMENT 'ENTITY, FUND or DEPARTMENT',
    CODE, NAME, IS_ACTIVE,
    DISPLAY_ORDER COMMENT 'Sort order (departments); NULL otherwise'
)
COPY GRANTS
COMMENT = 'Values for the app dropdowns: entities, funds and departments.'
AS
SELECT 'ENTITY', ENTITY_CODE, ENTITY_NAME, IS_ACTIVE, NULL FROM {{ schema_app }}.T_D_ENTITY
UNION ALL
SELECT 'FUND', FUND_CODE, FUND_NAME, IS_ACTIVE, NULL FROM {{ schema_app }}.T_D_FUND
UNION ALL
SELECT 'DEPARTMENT', DEPARTMENT_CODE, DEPARTMENT_NAME, IS_ACTIVE, DISPLAY_ORDER FROM {{ schema_app }}.T_D_DEPARTMENT;
