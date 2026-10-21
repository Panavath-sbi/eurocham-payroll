-- depends_on: {{ ref('t_d_app_user') }}
/* =====================================================================================
   V_D_PBI_SIGNATURE - Power BI: approver e-signatures (from APP.T_D_APP_USER.SIGNATURE_IMAGE)
   =====================================================================================

   HISTORY
   -------
   2026-09-30  Initial version: EmployeeParams, DimEmployee, Employee_Details.
   2026-10-02  V1.5.0: tables in APP, base views in RPT (CORE removed).
               Payroll_Approval reads approvals by scenario + period (no request) and the
               assigned approver from T_D_APP_USER.ROLE_CODE. Fct_Payroll reads
               RPT.V_F_COST_ALLOCATION; Tot_Allowance = outstanding-leave payouts only
               (payroll adjustments were removed). New RPT.V_D_PBI_SIGNATURE replaces the
               RPT.SIGNATURES table (same column names).
   2026-10-19  Own file for DLSync (was in R__views_pbi.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.

   NOTES
   -----
   * "Current year" = the calendar year of CURRENT_DATE(), as DynamicFiscalYear did.
   * Only real employees are shown (planned hires of budgets / forecasts are excluded).
   ===================================================================================== */
/* -------------------------------------------------------------------------------------
   eSignature  ->  RPT.V_D_PBI_SIGNATURE
   One row per app user with a signature. Same column names as the former RPT.SIGNATURES
   table, so the Power BI query only needs its source changed to this view.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW V_D_PBI_SIGNATURE (
    APPROVER_EMAIL COMMENT 'Email of the approver (app user)',
    IMAGE_BASE64   COMMENT 'E-signature image in Base64'
)
COPY GRANTS
COMMENT = 'Power BI: approver e-signatures (from APP.T_D_APP_USER.SIGNATURE_IMAGE)'
AS
SELECT USER_EMAIL, SIGNATURE_IMAGE
FROM T_D_APP_USER
WHERE SIGNATURE_IMAGE IS NOT NULL;
