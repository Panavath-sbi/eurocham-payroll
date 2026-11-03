
CREATE OR REPLACE VIEW RPT.V_F_PBI_PAYROLL (
    "CostCenter"             COMMENT 'CC_9999-Shared for ECCC, CCIFC for CCIFC',
    "CostCenter_Department"  COMMENT 'Always Default (the department split is used in the app only)',
    "Employee_ID"            COMMENT 'Resource ID, e.g. HR-FRA-001',
    "Employee_Name"          COMMENT 'First name and last name',
    "Email"                  COMMENT 'Employee email',
    "TaxResidency_Name"      COMMENT 'Resident or Non-Resident, from the contract of the month',
    "Month"                  COMMENT 'Month code M01..M12',
    "Month_Full"             COMMENT 'Full month name, e.g. April',
    "Tot_Allowance"          COMMENT 'Outstanding leave payout, USD',
    "Present_Working_Days"   COMMENT 'Working days minus absence days (not split)',
    "Dep_Count"              COMMENT 'Number of dependants (children + spouse) (not split)',
    "Gross_Compensation"     COMMENT 'Gross pay USD = all earnings',
    "Base_Salary"            COMMENT 'Base salary USD',
    "ToS_Taxable_Base"       COMMENT 'Taxable base USD before dependant relief',
    "ToS_Rate"               COMMENT 'Tax bracket rate, e.g. 0.1; 0.2 for non-residents (not split)',
    "NSSF_EE_Total"          COMMENT 'Employee NSSF USD',
    "Annual_Bonus"           COMMENT 'Bonus USD',
    "NSSF_ER_Total"          COMMENT 'Employer NSSF USD: pension + health + occupational risk',
    "ToS_Withheld"           COMMENT 'Salary tax withheld USD',
    "Net_Salary_Bank"        COMMENT 'Net pay USD paid to the bank',
    "Overtime"               COMMENT 'Overtime USD',
    "Seniority_Pay"          COMMENT 'Seniority payment USD',
    "Unpaid_Leave"           COMMENT 'Unpaid leave USD, as stored by the calculation',
    "ECCC_Fund"              COMMENT 'Gross USD charged to the ECCC fund',
    "CCIFC_Fund"             COMMENT 'Gross USD charged to the CCIFC fund',
    "EU_Gate_Fund"           COMMENT 'Gross USD charged to the EU GATE fund',
    "Total_Fund"             COMMENT 'Gross USD of the row (sum of the three funds)',
    "ECCC_Pct"               COMMENT 'ECCC fund share, 0..1',
    "CCIFC_Pct"              COMMENT 'CCIFC fund share, 0..1',
    "EU_Gate_Pct"            COMMENT 'EU GATE fund share, 0..1',
    "Gross_Compensation_KHR" COMMENT 'Gross pay KHR',
    "Base_Salary_KHR"        COMMENT 'Base salary KHR',
    "ToS_Taxable_Base_KHR"   COMMENT 'Taxable base KHR',
    "NSSF_EE_Total_KHR"      COMMENT 'Employee NSSF KHR',
    "NSSF_ER_Total_KHR"      COMMENT 'Employer NSSF KHR',
    "Annual_Bonus_KHR"       COMMENT 'Bonus KHR',
    "ToS_Withheld_KHR"       COMMENT 'Salary tax KHR',
    "Net_Salary_Bank_KHR"    COMMENT 'Net pay KHR, informational',
    "Seniority_Pay_KHR"      COMMENT 'Seniority payment KHR',
    "ECCC_Fund_KHR"          COMMENT 'Gross KHR charged to the ECCC fund',
    "CCIFC_Fund_KHR"         COMMENT 'Gross KHR charged to the CCIFC fund',
    "EU_Gate_Fund_KHR"       COMMENT 'Gross KHR charged to the EU GATE fund',
    "Total_Fund_KHR"         COMMENT 'Gross KHR of the row',
    "ECCC_Pct_KHR"           COMMENT 'ECCC fund share, 0..1 (same as ECCC_Pct)',
    "CCIFC_Pct_KHR"          COMMENT 'CCIFC fund share, 0..1 (same as CCIFC_Pct)',
    "EU_Gate_Pct_KHR"        COMMENT 'EU GATE fund share, 0..1 (same as EU_Gate_Pct)',
    "Employee_Position"      COMMENT 'Job title from the contract of the month'
)
COPY GRANTS
COMMENT = 'Power BI: Fct_Payroll (actual payroll, current year, employee x month)'
AS
WITH months AS (           -- actual payroll months of the current year
    SELECT sp.SCENARIO_ID, sp.PERIOD_KEY, sp.WORKING_DAYS, p.MONTH_NUMBER, p.PERIOD_START_DATE
    FROM APP.T_F_SCENARIO_PERIOD sp
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = sp.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
    JOIN APP.T_D_PERIOD p  ON p.PERIOD_KEY = sp.PERIOD_KEY
    WHERE p.YEAR = YEAR(CURRENT_DATE())
),
amounts AS (               -- one row per employee and month, pay components pivoted
    SELECT
        l.SCENARIO_ID, l.PERIOD_KEY, l.EMPLOYEE_ID,
        MAX(l.ENTITY_CODE) AS ENTITY_CODE,
        -- USD
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BASE_SALARY',     l.AMOUNT_USD, 0)), 2) AS BASE_SALARY_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BONUS',           l.AMOUNT_USD, 0)), 2) AS BONUS_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'OVERTIME',        l.AMOUNT_USD, 0)), 2) AS OVERTIME_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SENIORITY',       l.AMOUNT_USD, 0)), 2) AS SENIORITY_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'UNPAID_LEAVE',    l.AMOUNT_USD, 0)), 2) AS UNPAID_LEAVE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'OUTSTANDING_LEAVE', l.AMOUNT_USD, 0)), 2) AS ALLOWANCE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'TAXABLE_BASE',    l.AMOUNT_USD, 0)), 2) AS TAXABLE_BASE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'NSSF_EE_PENSION', l.AMOUNT_USD, 0)), 2) AS NSSF_EE_USD,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SALARY_TAX',      l.AMOUNT_USD, 0)), 2) AS SALARY_TAX_USD,
        ROUND(SUM(IFF(pc.CATEGORY = 'EARNING',                  l.AMOUNT_USD, 0)), 2) AS GROSS_USD,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYEE_DEDUCTION',       l.AMOUNT_USD, 0)), 2) AS DEDUCTIONS_USD,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYER_CONTRIBUTION',    l.AMOUNT_USD, 0)), 2) AS NSSF_ER_USD,
        -- KHR
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BASE_SALARY',     l.AMOUNT_KHR, 0)), 0) AS BASE_SALARY_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'BONUS',           l.AMOUNT_KHR, 0)), 0) AS BONUS_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SENIORITY',       l.AMOUNT_KHR, 0)), 0) AS SENIORITY_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'TAXABLE_BASE',    l.AMOUNT_KHR, 0)), 0) AS TAXABLE_BASE_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'NSSF_EE_PENSION', l.AMOUNT_KHR, 0)), 0) AS NSSF_EE_KHR,
        ROUND(SUM(IFF(l.PAY_COMPONENT_CODE = 'SALARY_TAX',      l.AMOUNT_KHR, 0)), 0) AS SALARY_TAX_KHR,
        ROUND(SUM(IFF(pc.CATEGORY = 'EARNING',                  l.AMOUNT_KHR, 0)), 0) AS GROSS_KHR,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYEE_DEDUCTION',       l.AMOUNT_KHR, 0)), 0) AS DEDUCTIONS_KHR,
        ROUND(SUM(IFF(pc.CATEGORY = 'EMPLOYER_CONTRIBUTION',    l.AMOUNT_KHR, 0)), 0) AS NSSF_ER_KHR,
        SUM(IFF(l.PAY_COMPONENT_CODE = 'TAX_CALC_BASE',         l.AMOUNT_KHR, 0))     AS TAX_CALC_BASE_KHR
    FROM APP.T_F_PAYROLL_LINE l
    JOIN APP.T_D_PAY_COMPONENT pc ON pc.PAY_COMPONENT_CODE = l.PAY_COMPONENT_CODE
    JOIN months m                  ON m.SCENARIO_ID = l.SCENARIO_ID AND m.PERIOD_KEY = l.PERIOD_KEY
    GROUP BY l.SCENARIO_ID, l.PERIOD_KEY, l.EMPLOYEE_ID
),
fund_raw AS (              -- fund shares 0..1 per employee and month; 0 when there is no fund split
    SELECT am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, am.ENTITY_CODE,
           COALESCE(SUM(IFF(fa.FUND_CODE = 'ECCC',    fa.SHARE_PCT / 100, 0)), 0) AS ECCC_RAW,
           COALESCE(SUM(IFF(fa.FUND_CODE = 'CCIFC',   fa.SHARE_PCT / 100, 0)), 0) AS CCIFC_RAW,
           COALESCE(SUM(IFF(fa.FUND_CODE = 'EU_GATE', fa.SHARE_PCT / 100, 0)), 0) AS EU_GATE_RAW
    FROM amounts am
    LEFT JOIN APP.T_F_FUND_ALLOCATION fa
           ON fa.SCENARIO_ID = am.SCENARIO_ID AND fa.PERIOD_KEY = am.PERIOD_KEY AND fa.EMPLOYEE_ID = am.EMPLOYEE_ID
    GROUP BY am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, am.ENTITY_CODE
),
fund_share AS (            -- any share without a fund goes to the employee's entity fund
    SELECT f.SCENARIO_ID, f.PERIOD_KEY, f.EMPLOYEE_ID,
           f.ECCC_RAW    + IFF(f.ENTITY_CODE = 'ECCC',  GREATEST(1 - f.ECCC_RAW - f.CCIFC_RAW - f.EU_GATE_RAW, 0), 0) AS ECCC_SHARE,
           f.CCIFC_RAW   + IFF(f.ENTITY_CODE = 'CCIFC', GREATEST(1 - f.ECCC_RAW - f.CCIFC_RAW - f.EU_GATE_RAW, 0), 0) AS CCIFC_SHARE,
           f.EU_GATE_RAW                                                                                               AS EU_GATE_SHARE
    FROM fund_raw f
),
month_contract AS (        -- contract version in force in the payroll month
    SELECT am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, c.POSITION, c.TAX_STATUS,
           COALESCE(c.DEPENDANT_CHILDREN, 0) + COALESCE(c.DEPENDANT_SPOUSE::INT, 0) AS DEP_COUNT
    FROM amounts am
    JOIN APP.T_D_EMPLOYEE_CONTRACT c
      ON c.EMPLOYEE_ID = am.EMPLOYEE_ID
     AND c.VALID_FROM_PERIOD_KEY <= am.PERIOD_KEY
     AND (c.VALID_TO_PERIOD_KEY IS NULL OR c.VALID_TO_PERIOD_KEY >= am.PERIOD_KEY)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID
                               ORDER BY c.VALID_FROM_PERIOD_KEY DESC) = 1
),
tax_rate AS (              -- highest bracket whose lower bound the taxable base exceeds
    SELECT am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID, tb.TAX_RATE
    FROM amounts am
    JOIN APP.T_P_TAX_BRACKET tb
      ON tb.VALID_FROM_PERIOD_KEY <= am.PERIOD_KEY
     AND (tb.VALID_TO_PERIOD_KEY IS NULL OR tb.VALID_TO_PERIOD_KEY >= am.PERIOD_KEY)
     AND am.TAX_CALC_BASE_KHR > tb.LOWER_BOUND_KHR
    QUALIFY ROW_NUMBER() OVER (PARTITION BY am.SCENARIO_ID, am.PERIOD_KEY, am.EMPLOYEE_ID
                               ORDER BY tb.BRACKET_NUMBER DESC) = 1
)
SELECT
    IFF(am.ENTITY_CODE = 'ECCC', 'CC_9999-Shared', am.ENTITY_CODE)                  AS "CostCenter",
    'Default'                                                                       AS "CostCenter_Department",
    e.RESOURCE_CODE                                                                 AS "Employee_ID",
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, ''))            AS "Employee_Name",
    e.EMAIL                                                                         AS "Email",
    IFF(mc.TAX_STATUS = 'NON_RESIDENT', 'Non-Resident', 'Resident')                 AS "TaxResidency_Name",
    'M' || LPAD(m.MONTH_NUMBER, 2, '0')                                             AS "Month",
    TO_CHAR(m.PERIOD_START_DATE, 'MMMM')                                            AS "Month_Full",
    am.ALLOWANCE_USD::FLOAT                                                AS "Tot_Allowance",
    (COALESCE(m.WORKING_DAYS, 0) - COALESCE(pi.ABSENCE_DAYS, 0))::FLOAT             AS "Present_Working_Days",
    COALESCE(mc.DEP_COUNT, 0)::INT                                                  AS "Dep_Count",
    am.GROSS_USD::FLOAT                                                    AS "Gross_Compensation",
    am.BASE_SALARY_USD::FLOAT                                              AS "Base_Salary",
    am.TAXABLE_BASE_USD::FLOAT                                             AS "ToS_Taxable_Base",
    IFF(mc.TAX_STATUS = 'NON_RESIDENT', 0.2, COALESCE(tr.TAX_RATE, 0))::FLOAT       AS "ToS_Rate",
    am.NSSF_EE_USD::FLOAT                                                  AS "NSSF_EE_Total",
    am.BONUS_USD::FLOAT                                                    AS "Annual_Bonus",
    am.NSSF_ER_USD::FLOAT                                                  AS "NSSF_ER_Total",
    am.SALARY_TAX_USD::FLOAT                                               AS "ToS_Withheld",
    ((am.GROSS_USD - am.DEDUCTIONS_USD))::FLOAT                              AS "Net_Salary_Bank",
    am.OVERTIME_USD::FLOAT                                                 AS "Overtime",
    am.SENIORITY_USD::FLOAT                                                AS "Seniority_Pay",
    am.UNPAID_LEAVE_USD::FLOAT                                             AS "Unpaid_Leave",
    (am.GROSS_USD * fs.ECCC_SHARE)::FLOAT                                    AS "ECCC_Fund",
    (am.GROSS_USD * fs.CCIFC_SHARE)::FLOAT                                   AS "CCIFC_Fund",
    (am.GROSS_USD * fs.EU_GATE_SHARE)::FLOAT                                 AS "EU_Gate_Fund",
    am.GROSS_USD::FLOAT                                                    AS "Total_Fund",
    fs.ECCC_SHARE::FLOAT                                                            AS "ECCC_Pct",
    fs.CCIFC_SHARE::FLOAT                                                           AS "CCIFC_Pct",
    fs.EU_GATE_SHARE::FLOAT                                                         AS "EU_Gate_Pct",
    am.GROSS_KHR::FLOAT                                                    AS "Gross_Compensation_KHR",
    am.BASE_SALARY_KHR::FLOAT                                              AS "Base_Salary_KHR",
    am.TAXABLE_BASE_KHR::FLOAT                                             AS "ToS_Taxable_Base_KHR",
    am.NSSF_EE_KHR::FLOAT                                                  AS "NSSF_EE_Total_KHR",
    am.NSSF_ER_KHR::FLOAT                                                  AS "NSSF_ER_Total_KHR",
    am.BONUS_KHR::FLOAT                                                    AS "Annual_Bonus_KHR",
    am.SALARY_TAX_KHR::FLOAT                                               AS "ToS_Withheld_KHR",
    ((am.GROSS_KHR - am.DEDUCTIONS_KHR))::FLOAT                              AS "Net_Salary_Bank_KHR",
    am.SENIORITY_KHR::FLOAT                                                AS "Seniority_Pay_KHR",
    (am.GROSS_KHR * fs.ECCC_SHARE)::FLOAT                                    AS "ECCC_Fund_KHR",
    (am.GROSS_KHR * fs.CCIFC_SHARE)::FLOAT                                   AS "CCIFC_Fund_KHR",
    (am.GROSS_KHR * fs.EU_GATE_SHARE)::FLOAT                                 AS "EU_Gate_Fund_KHR",
    am.GROSS_KHR::FLOAT                                                    AS "Total_Fund_KHR",
    fs.ECCC_SHARE::FLOAT                                                            AS "ECCC_Pct_KHR",
    fs.CCIFC_SHARE::FLOAT                                                           AS "CCIFC_Pct_KHR",
    fs.EU_GATE_SHARE::FLOAT                                                         AS "EU_Gate_Pct_KHR",
    mc.POSITION                                                                     AS "Employee_Position"
FROM amounts am
JOIN months m              ON m.SCENARIO_ID = am.SCENARIO_ID AND m.PERIOD_KEY = am.PERIOD_KEY
JOIN APP.T_D_EMPLOYEE e    ON e.EMPLOYEE_ID = am.EMPLOYEE_ID AND NOT e.IS_PLANNED
JOIN fund_share fs         ON fs.SCENARIO_ID = am.SCENARIO_ID AND fs.PERIOD_KEY = am.PERIOD_KEY
                          AND fs.EMPLOYEE_ID = am.EMPLOYEE_ID
LEFT JOIN month_contract mc ON mc.SCENARIO_ID = am.SCENARIO_ID AND mc.PERIOD_KEY = am.PERIOD_KEY
                          AND mc.EMPLOYEE_ID = am.EMPLOYEE_ID
LEFT JOIN tax_rate tr      ON tr.SCENARIO_ID = am.SCENARIO_ID AND tr.PERIOD_KEY = am.PERIOD_KEY
                          AND tr.EMPLOYEE_ID = am.EMPLOYEE_ID
LEFT JOIN APP.T_F_PAYROLL_INPUT pi ON pi.SCENARIO_ID = am.SCENARIO_ID AND pi.PERIOD_KEY = am.PERIOD_KEY
                          AND pi.EMPLOYEE_ID = am.EMPLOYEE_ID;
