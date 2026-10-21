-- depends_on: {{ ref('t_p_approval_step') }}, {{ ref('t_d_app_user') }}
/* =====================================================================================
   V_P_APPROVAL_STEP - The approval chain as it applies in the current calendar month, with the assigned approver
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
   Approval steps in force this month, with their approver: Settings page
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_P_APPROVAL_STEP (
    STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, MANAGES_EMPLOYEE_CHECKS, VALID_FROM_PERIOD_KEY,
    APPROVER_EMAIL COMMENT 'Active user holding the step''s role (several separated by ; if the data allows it)',
    APPROVER_NAME  COMMENT 'Display name of that user'
)
COPY GRANTS
COMMENT = 'The approval chain as it applies in the current calendar month, with the assigned approver.'
AS
SELECT
    st.STEP_ORDER,
    st.STEP_TITLE,
    st.APPROVER_ROLE,
    st.APPLIES_TO,
    COALESCE(st.MANAGES_EMPLOYEE_CHECKS, FALSE),
    st.VALID_FROM_PERIOD_KEY,
    LISTAGG(u.USER_EMAIL, '; ')   WITHIN GROUP (ORDER BY u.USER_EMAIL),
    LISTAGG(u.DISPLAY_NAME, '; ') WITHIN GROUP (ORDER BY u.USER_EMAIL)
FROM T_P_APPROVAL_STEP st
LEFT JOIN T_D_APP_USER u ON u.ROLE_CODE = st.APPROVER_ROLE AND u.IS_ACTIVE
WHERE st.IS_ACTIVE
  AND TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'))
      BETWEEN st.VALID_FROM_PERIOD_KEY AND COALESCE(st.VALID_TO_PERIOD_KEY, 999912)
GROUP BY st.STEP_ORDER, st.STEP_TITLE, st.APPROVER_ROLE, st.APPLIES_TO,
         st.MANAGES_EMPLOYEE_CHECKS, st.VALID_FROM_PERIOD_KEY;
