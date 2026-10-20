/* =====================================================================================
   PAYROLL DATA MODEL - 04 TESTS: PAYROLL CYCLE PROCEDURES
   Run on a fresh dev database: the dbt build, then dev_data/load_dummy_data.sql,
   then this script, top to bottom. Never run in production.
   Each test states the expected result. The tests change the dummy data.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-09-29  Moved to tests/ for Git; USE DATABASE removed (set per environment).
   2026-09-29  Renamed test_01_payroll_cycle.sql; run test_02_remaining_procedures.sql after it.
   2026-10-02  Approvals: one state row per step (T_F_APPROVAL_STEP_STATE); checks without step (4a, 4b, 10).
   2026-10-02  V1.5.0: tables in APP, views in RPT; cost allocation read from the view
               RPT.V_F_COST_ALLOCATION (1c); checks read from T_F_PAYROLL_INPUT (4b);
               approvals in T_F_APPROVAL by scenario + period (4c, 10).
   2026-10-06  V1.7.0 roles: TEST 3 checks an unknown user instead of a budget editor.
   ===================================================================================== */


SET ACTUAL_ID = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL');
SET BASE_ID   = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = 'Budget 2027 Base');
SET GROWTH_ID = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = 'Budget 2027 Growth');
SET SOKHA_ID  = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = 'HR-KH-001');
SET MARTIN_ID = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = 'HR-FR-002');

/* -------------------------------------------------------------------------------------
   TEST 1 - Recalculate the open month (Oct 2026) for all employees
   Expected: status OK, "1 period(s) calculated."
   ------------------------------------------------------------------------------------- */
CALL APP.SP_CALCULATE_PAYROLL('admin@example.org', $ACTUAL_ID, 202610);

-- 1a. Sokha's October lines must match the hand-calculated example (MATCHES = TRUE on every row)
WITH expected AS (
    SELECT * FROM VALUES
        ('BASE_SALARY',      1000.00, 4085000),
        ('UNPAID_LEAVE',     -90.91,  -371364),
        ('NSSF_BASE',        296.30,  1200000),
        ('NSSF_EE_PENSION',  5.88,    24000),
        ('NSSF_ER_PENSION',  5.88,    24000),
        ('NSSF_ER_HEALTH',   7.64,    31200),
        ('NSSF_ER_ORC',      2.35,    9600),
        ('TAXABLE_BASE',     903.22,  3689636),
        ('DEPENDANT_RELIEF', 73.44,   300000),
        ('TAX_CALC_BASE',    829.78,  3389636),
        ('SALARY_TAX',       40.14,   163964),
        ('INSURANCE',        30.00,   122550)
        AS e (COMPONENT, USD, KHR)
),
actual_lines AS (
    SELECT PAY_COMPONENT_CODE, AMOUNT_USD, AMOUNT_KHR
    FROM APP.T_F_PAYROLL_LINE
    WHERE SCENARIO_ID = $ACTUAL_ID AND PERIOD_KEY = 202610 AND EMPLOYEE_ID = $SOKHA_ID
)
SELECT COALESCE(e.COMPONENT, a.PAY_COMPONENT_CODE) AS COMPONENT,
       e.USD AS EXPECTED_USD, a.AMOUNT_USD AS ACTUAL_USD,
       e.KHR AS EXPECTED_KHR, a.AMOUNT_KHR AS ACTUAL_KHR,
       COALESCE(ABS(e.USD - a.AMOUNT_USD) < 0.005 AND e.KHR = a.AMOUNT_KHR, FALSE) AS MATCHES
FROM expected e
FULL JOIN actual_lines a ON a.PAY_COMPONENT_CODE = e.COMPONENT
ORDER BY COMPONENT;

-- 1b. Summary. Expected Sokha Oct: gross 909.09, net 863.07, employer cost 954.96
SELECT e.RESOURCE_CODE, s.PERIOD_KEY, s.GROSS_PAY_USD, s.NSSF_EE_USD, s.SALARY_TAX_USD,
       s.NET_PAY_USD, s.NSSF_ER_USD, s.OTHER_EMPLOYER_COST_USD, s.EMPLOYER_COST_USD
FROM RPT.V_F_PAYROLL_SUMMARY s
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = s.EMPLOYEE_ID
WHERE s.SCENARIO_ID = $ACTUAL_ID
ORDER BY s.PERIOD_KEY, e.RESOURCE_CODE;

-- 1c. Cost allocation. Expected Sokha: Admin 545.45 / 572.98, Advocacy 363.64 / 381.98;
--     Martin split 70 / 30 between ECCC and EU Gate; Dara 100% CCIFC Services
SELECT e.RESOURCE_CODE, a.FUND_CODE, a.DEPARTMENT_CODE, a.ALLOCATION_SHARE, a.GROSS_PAY_USD, a.EMPLOYER_COST_USD
FROM RPT.V_F_COST_ALLOCATION a
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = a.EMPLOYEE_ID
WHERE a.SCENARIO_ID = $ACTUAL_ID AND a.PERIOD_KEY = 202610
ORDER BY e.RESOURCE_CODE, a.FUND_CODE, a.DEPARTMENT_CODE;

/* -------------------------------------------------------------------------------------
   TEST 2 - A finalized month cannot be recalculated
   Expected: status ERROR, "Nothing calculated: ... finalized / locked."
   ------------------------------------------------------------------------------------- */
CALL APP.SP_CALCULATE_PAYROLL('admin@example.org', $ACTUAL_ID, 202609);

/* -------------------------------------------------------------------------------------
   TEST 3 - Access check: someone who is not an app user cannot calculate
   (any active user can: roles only limit approvals)
   Expected: status ERROR, "You are not an active app user. Ask a developer to add you in Snowflake."
   ------------------------------------------------------------------------------------- */
CALL APP.SP_CALCULATE_PAYROLL('nobody@example.org', $ACTUAL_ID, 202610);

/* -------------------------------------------------------------------------------------
   TEST 4 - Save a monthly input: Martin's overtime 1 -> 0
   Expected: status OK, "1 employee(s) updated and payroll recalculated."
   Side effects: step 1 goes back to PENDING (LAST_ACTION RESET); Martin's check goes back
   to PENDING; rows in T_F_CHANGE_LOG for the input change and the reset.
   ------------------------------------------------------------------------------------- */
SET INPUTS = (SELECT '[{"employee_id": ' || $MARTIN_ID || ', "overtime_days": 0}]');
CALL APP.SP_SAVE_MONTHLY_INPUT('admin@example.org', $ACTUAL_ID, 202610, $INPUTS);

-- 4a. Approval progress for Oct. Expected: step 1 now PENDING (LAST_ACTION RESET), step 1 is next;
--     MANAGES_EMPLOYEE_CHECKS is TRUE for step 2 only
SELECT p.PERIOD_KEY, p.STEP_ORDER, p.STEP_TITLE, p.STEP_STATUS, p.LAST_ACTION, p.IS_NEXT_STEP, p.MANAGES_EMPLOYEE_CHECKS
FROM RPT.V_F_APPROVAL_PROGRESS p
WHERE p.SCENARIO_ID = $ACTUAL_ID AND p.PERIOD_KEY = 202610
ORDER BY p.STEP_ORDER;

-- 4b. Employee checks (one per employee). Expected: Martin PENDING (was REJECTED);
--     and its rejection comment cleared; Sokha still CHECKED; Dara PENDING
SELECT e.RESOURCE_CODE, i.CHECK_STATUS, i.CHECK_COMMENT, i.CHECKED_BY
FROM APP.T_F_PAYROLL_INPUT i
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = i.EMPLOYEE_ID
WHERE i.SCENARIO_ID = $ACTUAL_ID AND i.PERIOD_KEY = 202610
ORDER BY e.RESOURCE_CODE;

-- 4c. Audit trail. Expected: newest row is the RESET of step 1 (TABLE_NAME APP.T_F_APPROVAL);
--     the row before it shows OVERTIME_DAYS 1 -> 0 by admin@example.org
SELECT TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES:OVERTIME_DAYS AS OLD_OT, NEW_VALUES:OVERTIME_DAYS AS NEW_OT, CHANGED_BY
FROM APP.T_F_CHANGE_LOG
ORDER BY CHANGE_ID DESC
LIMIT 3;

/* -------------------------------------------------------------------------------------
   TEST 5 - Saving the same values again changes nothing
   Expected: status OK, "No changes to save."
   ------------------------------------------------------------------------------------- */
CALL APP.SP_SAVE_MONTHLY_INPUT('admin@example.org', $ACTUAL_ID, 202610, $INPUTS);

/* -------------------------------------------------------------------------------------
   TEST 6 - Validation: more absence days than working days (22)
   Expected: status ERROR, "1 row(s) have ... more absence days than working days (22)."
   ------------------------------------------------------------------------------------- */
SET BAD_INPUTS = (SELECT '[{"employee_id": ' || $SOKHA_ID || ', "absence_days": 30}]');
CALL APP.SP_SAVE_MONTHLY_INPUT('admin@example.org', $ACTUAL_ID, 202610, $BAD_INPUTS);

/* -------------------------------------------------------------------------------------
   TEST 7 - Validation: salary override is not allowed on actual payroll
   Expected: status ERROR, "Salary and fringe overrides are only allowed in budgets and forecasts..."
   ------------------------------------------------------------------------------------- */
SET OVR_INPUTS = (SELECT '[{"employee_id": ' || $SOKHA_ID || ', "salary_override_usd": 1200}]');
CALL APP.SP_SAVE_MONTHLY_INPUT('admin@example.org', $ACTUAL_ID, 202610, $OVR_INPUTS);

/* -------------------------------------------------------------------------------------
   TEST 8 - Finalize is refused while approvals are missing
   Expected: status ERROR, "3 approval step(s) are not approved yet."
   ------------------------------------------------------------------------------------- */
CALL APP.SP_FINALIZE_PAYROLL('admin@example.org', 202610);

/* -------------------------------------------------------------------------------------
   TEST 9 - Opening November is refused while October is open
   Expected: status ERROR, "Another payroll month is still open. Finalize it first."
   ------------------------------------------------------------------------------------- */
CALL APP.SP_OPEN_PAYROLL_PERIOD('admin@example.org', 202611);

/* -------------------------------------------------------------------------------------
   TEST 10 - Full cycle: approve Oct by hand (approval procedures come next), finalize,
   then open November
   Expected: finalize OK; open OK "Payroll 202611 opened for 3 employees.";
   Sokha's November lines use the new contract (BASE_SALARY 1,100.00)
   ------------------------------------------------------------------------------------- */
UPDATE APP.T_F_APPROVAL t
SET STEP_STATUS = 'APPROVED', LAST_ACTION = 'APPROVE', ACTED_BY = x.BY_USER, ACTED_AT = CURRENT_TIMESTAMP,
    STEP_COMMENT = 'Test approval'
FROM (SELECT * FROM VALUES (1, 'hr@example.org'), (2, 'treasurer@example.org'), (3, 'director@example.org')
      AS v (STEP_ORDER, BY_USER)) x
WHERE t.SCENARIO_ID = $ACTUAL_ID AND t.PERIOD_KEY = 202610 AND t.STEP_ORDER = x.STEP_ORDER;

CALL APP.SP_FINALIZE_PAYROLL('admin@example.org', 202610);

-- November needs FX rates (otherwise October's applied rates are reused) and working days (21 in the dummy data)
CALL APP.SP_OPEN_PAYROLL_PERIOD('admin@example.org', 202611);

SELECT e.RESOURCE_CODE, l.PERIOD_KEY, l.PAY_COMPONENT_CODE, l.AMOUNT_USD, l.EMPLOYEE_VERSION_KEY
FROM APP.T_F_PAYROLL_LINE l
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = l.EMPLOYEE_ID
WHERE l.SCENARIO_ID = $ACTUAL_ID AND l.PERIOD_KEY = 202611 AND l.PAY_COMPONENT_CODE = 'BASE_SALARY'
ORDER BY e.RESOURCE_CODE;

-- October is now read-only: expected ERROR "Period 202610 is FINALIZED and cannot be edited."
CALL APP.SP_SAVE_MONTHLY_INPUT('admin@example.org', $ACTUAL_ID, 202610, $INPUTS);

/* -------------------------------------------------------------------------------------
   TEST 11 - Budget: calculate all 12 months of "Budget 2027 Growth"
   Expected: status OK, "12 period(s) calculated."
   Sokha's June seniority: salary 1,100 Jan-Mar and 1,210 Apr-Jun -> average 1,155;
   1,155 / 22 working days x 7.5 = 393.75
   (Note: the dummy planned intern has no input rows for Feb-May, so it is included
   in those months; the planned-hire procedure will create the rows properly.)
   ------------------------------------------------------------------------------------- */
CALL APP.SP_CALCULATE_PAYROLL('clerk@example.org', $GROWTH_ID, NULL);

SELECT e.RESOURCE_CODE, l.PERIOD_KEY, l.PAY_COMPONENT_CODE, l.AMOUNT_USD
FROM APP.T_F_PAYROLL_LINE l
JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = l.EMPLOYEE_ID
WHERE l.SCENARIO_ID = $GROWTH_ID AND l.PAY_COMPONENT_CODE IN ('BASE_SALARY', 'SENIORITY')
  AND e.RESOURCE_CODE = 'HR-KH-001'
ORDER BY l.PERIOD_KEY, l.PAY_COMPONENT_CODE;

-- The official (locked) Base budget cannot be recalculated. Expected: status ERROR
CALL APP.SP_CALCULATE_PAYROLL('clerk@example.org', $BASE_ID, NULL);

-- End of script
