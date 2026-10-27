-- depends_on: V_F_PBI_PAYSLIP, FN_PAYSLIP_PDF
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   V_F_PAYSLIP_DOC - Payslip PDF per employee x finalized actual month (payslip flow)
   =====================================================================================

   HISTORY
   -------
   2026-10-27  Initial version: the payslip PDF (base64) made by APP.FN_PAYSLIP_PDF from
               RPT.V_F_PBI_PAYSLIP, replacing the paginated report export in the flow.

   NOTES
   -----
   * Always filter on "Period_Key" AND "Employee_ID": one row = one PDF, made when the
     row is read (8-9 s each). A SELECT without a filter makes a PDF for every row.
   * Nothing is stored: the PDF exists only in the query result. The flow turns it into
     the email attachment with base64ToBinary().
   * Same rows as RPT.V_F_PBI_PAYSLIP (finalized actual months only).
   * Keys of the object = field names of the fillable form on APP.PAYSLIP_TEMPLATE.
     The mapping follows EuroCham Payslip.rdl, except NSSF (employee part only, decided
     2026-10-27, so the slip adds up to net pay).
   * Read with the view owner's rights: readers need SELECT on this view only, no
     rights on the function or the stage.
   ===================================================================================== */
CREATE OR REPLACE VIEW RPT.V_F_PAYSLIP_DOC (
    "Period_Key"    COMMENT 'Payroll month YYYYMM, e.g. 202610 (filter on it)',
    "Employee_ID"   COMMENT 'Resource ID, e.g. HR-FRA-001 (filter on it)',
    "Employee_Name" COMMENT 'First name and last name',
    "Email"         COMMENT 'Employee email the payslip is sent to',
    "Period_Label"  COMMENT 'Month and year, e.g. October 2026 (email subject and file name)',
    "PDF_Base64"    COMMENT 'Payslip PDF as base64 text; base64ToBinary() in the flow gives the file'
)
COPY GRANTS
COMMENT = 'Payslip PDF (base64) per employee x finalized actual month; filter on Period_Key and Employee_ID'
AS
SELECT
    p."Period_Key",
    p."Employee_ID",
    p."Employee_Name",
    p."Email",
    p."Period_Label",
    APP.FN_PAYSLIP_PDF(OBJECT_CONSTRUCT_KEEP_NULL(
        'Employee_ID',       p."Employee_ID",
        'Period',            p."Month_Full" || '-' || p."Year",
        'Employee_Name',     p."Employee_Name",
        'Employee_Position', p."Employee_Position",
        'Working_Days',      p."Present_Working_Days",
        'Unpaid_Leave',      p."Unpaid_Leave",
        'Seniority_Pay',     p."Seniority_Pay",
        'Bonus',             p."Annual_Bonus",
        'Gross_USD',         p."Gross_Compensation",
        'Total_Benefit',     p."Seniority_Pay" + p."Annual_Bonus",
        'Taxable_USD',       p."ToS_Taxable_Base",
        'Tax_USD',           p."ToS_Withheld",
        'NSSF_Deductions',   p."NSSF_EE_Total",
        'Net_Pay_USD',       p."Net_Salary_Bank",
        'ECCC_Pct',          p."ECCC_Pct",
        'CCIFC_Pct',         p."CCIFC_Pct",
        'EU_Gate_Pct',       p."EU_Gate_Pct",
        'ECCC_Amount',       p."ECCC_Fund",
        'CCIFC_Amount',      p."CCIFC_Fund",
        'EU_Gate_Amount',    p."EU_Gate_Fund",
        'FX_Rate',           p."FX_USD_KHR",
        'Gross_KHR',         p."Gross_Compensation_KHR",
        'Dep_Count',         p."Dep_Count",
        'Dependents_KHR',    p."Dep_Count" * 150000,
        'Tax_KHR',           p."ToS_Withheld_KHR",
        'Taxable_KHR',       p."ToS_Taxable_Base_KHR",
        'Tax_Rate',          p."ToS_Rate"
    ))                      AS "PDF_Base64"
FROM RPT.V_F_PBI_PAYSLIP p;
