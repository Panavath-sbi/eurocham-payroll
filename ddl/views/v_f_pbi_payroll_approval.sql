-- depends_on: T_D_APP_USER, V_F_APPROVAL_PROGRESS, T_D_PERIOD
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_PBI_PAYROLL_APPROVAL - Power BI: Payroll_Approval (replaces the SharePoint approval list)
   =====================================================================================

   HISTORY
   -------
   2026-09-30  Initial version: EmployeeParams, DimEmployee, Employee_Details.
   2026-09-30  Added Payroll_Approval (replaces the SharePoint approval list).
               Fct_Payroll to follow.
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
   Payroll_Approval  ->  RPT.V_F_PBI_PAYROLL_APPROVAL
   Replaces the SharePoint approval list: one row per approval step per actual payroll
   month of the current year (only months that have been opened).
   Title = YYYYMM. Approved_By / Approval_Date are filled once the step is approved or
   rejected; a pending step shows them empty, as in the list. Comments shows the latest
   comment on the step (for a step sent back, the reason it was sent back).
   Assigned_To = the email of the user(s) holding the step's approver role today.
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW RPT.V_F_PBI_PAYROLL_APPROVAL (
    "Title"           COMMENT 'Payroll month as YYYYMM, e.g. 202609',
    "Approval_Step"   COMMENT 'Step title, e.g. HR Manager',
    "Approved_By"     COMMENT 'Name of the approver who approved or rejected the step; empty while pending',
    "Approval_Date"   COMMENT 'When the step was approved or rejected; empty while pending',
    "Approval_Status" COMMENT 'Approved or Rejected; empty while pending',
    "Comments"        COMMENT 'Latest comment on the step',
    "Step_Order"      COMMENT 'Step sequence, 1 = first',
    "Assigned_To"     COMMENT 'Email of the user assigned to the step',
    "Approval_Type"   COMMENT 'Always Actuals',
    "Year"            COMMENT 'Payroll year',
    "MonthNo"         COMMENT 'Payroll month number 1-12'
)
COPY GRANTS
COMMENT = 'Power BI: Payroll_Approval (replaces the SharePoint approval list)'
AS
WITH assigned AS (         -- who holds each approver role today (one role per user)
    SELECT u.ROLE_CODE, LISTAGG(u.USER_EMAIL, '; ') WITHIN GROUP (ORDER BY u.USER_EMAIL) AS EMAILS
    FROM APP.T_D_APP_USER u
    WHERE u.IS_ACTIVE
    GROUP BY u.ROLE_CODE
)
SELECT
    pr.PERIOD_KEY::TEXT                                                   AS "Title",
    pr.STEP_TITLE                                                         AS "Approval_Step",
    IFF(pr.STEP_STATUS IN ('APPROVED', 'REJECTED'), COALESCE(u.DISPLAY_NAME, pr.ACTED_BY), NULL) AS "Approved_By",
    IFF(pr.STEP_STATUS IN ('APPROVED', 'REJECTED'), pr.ACTED_AT::TIMESTAMP_NTZ, NULL)            AS "Approval_Date",
    CASE pr.STEP_STATUS WHEN 'APPROVED' THEN 'Approved' WHEN 'REJECTED' THEN 'Rejected' END      AS "Approval_Status",
    pr.STEP_COMMENT                                                       AS "Comments",
    pr.STEP_ORDER::INT                                                    AS "Step_Order",
    a.EMAILS                                                              AS "Assigned_To",
    'Actuals'                                                             AS "Approval_Type",
    p.YEAR::INT                                                           AS "Year",
    p.MONTH_NUMBER::INT                                                   AS "MonthNo"
FROM RPT.V_F_APPROVAL_PROGRESS pr
JOIN APP.T_D_PERIOD p             ON p.PERIOD_KEY = pr.PERIOD_KEY
LEFT JOIN APP.T_D_APP_USER u      ON u.USER_EMAIL = pr.ACTED_BY
LEFT JOIN assigned a              ON a.ROLE_CODE = pr.APPROVER_ROLE
WHERE pr.SCENARIO_TYPE = 'ACTUAL'
  AND p.YEAR = YEAR(CURRENT_DATE());
