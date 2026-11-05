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
