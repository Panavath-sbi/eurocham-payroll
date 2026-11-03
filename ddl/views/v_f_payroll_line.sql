-- depends_on: T_F_PAYROLL_LINE, T_D_PAY_COMPONENT
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_PAYROLL_LINE - Calculated pay lines (scenario x month x employee x pay component) with the component name and category
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version: V_D_PERIOD, V_F_SCENARIO_PERIOD, V_F_PAYROLL_INPUT,
               V_F_ALLOCATION, V_D_SCENARIO_EMPLOYEE, V_F_PAYROLL_LINE, V_D_LOOKUP,
               V_P_APPROVAL_STEP, V_D_APP_USER.
   2026-10-19  Own file for DLSync (was in R__views_rpt_app.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.

   NOTES
   -----
   * No view here contains bank details or signature images: every app user reads through
     the same Snowflake connection, so anything in a view is visible to all of them.
   * Column comments: views inherit the meaning of the APP columns they show; only new or
     calculated columns are described.
   ===================================================================================== */
/* -------------------------------------------------------------------------------------
   Pay lines by component: cards that need one component (bonus, seniority, ToS ...)
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_PAYROLL_LINE (
    SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, PAY_COMPONENT_CODE, PAY_COMPONENT_NAME, CATEGORY,
    DISPLAY_ORDER, ENTITY_CODE, QUANTITY, RATE, AMOUNT_USD, AMOUNT_KHR, FX_RATE_APPLIED
)
COPY GRANTS
COMMENT = 'Calculated pay lines (scenario x month x employee x pay component) with the component name and category.'
AS
SELECT
    l.SCENARIO_ID,
    l.PERIOD_KEY,
    l.EMPLOYEE_ID,
    l.PAY_COMPONENT_CODE,
    pc.PAY_COMPONENT_NAME,
    pc.CATEGORY,
    pc.DISPLAY_ORDER,
    l.ENTITY_CODE,
    l.QUANTITY,
    l.RATE,
    l.AMOUNT_USD,
    l.AMOUNT_KHR,
    l.FX_RATE_APPLIED
FROM APP.T_F_PAYROLL_LINE l
JOIN APP.T_D_PAY_COMPONENT pc ON pc.PAY_COMPONENT_CODE = l.PAY_COMPONENT_CODE;
