/* =====================================================================================
   TESTS 02 - APPROVALS, SETTINGS, EMPLOYEES, BUDGETS, FORECASTS
   Run right after test_01_payroll_cycle.sql, on the same dev database (it continues
   from its end state: October finalized, November open). Top to bottom.
   Each test states the expected result. Never run in production.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version.
   2026-09-29  Reject now sends back one step (A9-A13); deactivation is immediate (C8, C10).
   ===================================================================================== */

SET ACTUAL_ID = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'ACTUAL');
SET GROWTH_ID = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = 'Budget 2027 Growth');
SET SOKHA_ID  = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = 'HR-KH-001');
SET MARTIN_ID = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = 'HR-FR-002');
SET DARA_ID   = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = 'HR-KH-003');
SET NOV_REQ   = (SELECT MAX(REQUEST_ID) FROM APP.T_F_APPROVAL_REQUEST
                 WHERE SCENARIO_ID = $ACTUAL_ID AND PERIOD_KEY = 202611 AND REQUEST_STATUS = 'IN_PROGRESS');


/* =====================================================================================
   A. APPROVALS (November payroll)
   ===================================================================================== */

-- A1. Expected ERROR: "3 employee(s) are not checked yet for this step."
CALL APP.SP_APPROVE_STEP('hr@example.org', $NOV_REQ, 1, NULL);

-- A2. Expected ERROR: "Only a user with role HR_MANAGER can act on step 1."
CALL APP.SP_SET_EMPLOYEE_CHECK('treasurer@example.org', $NOV_REQ, 1, NULL, 'CHECKED', NULL);

-- A3. Approve All for step 1. Expected OK: "3 employee check(s) set to CHECKED."
CALL APP.SP_SET_EMPLOYEE_CHECK('hr@example.org', $NOV_REQ, 1, NULL, 'CHECKED', NULL);

-- A4. Expected ERROR: "Only a user with role TREASURER can act on step 2."
CALL APP.SP_APPROVE_STEP('hr@example.org', $NOV_REQ, 2, NULL);

-- A5. Expected OK: "Step 1 approved."
CALL APP.SP_APPROVE_STEP('hr@example.org', $NOV_REQ, 1, 'Inputs look right');

-- A6. Reject Martin without a comment. Expected ERROR: "A comment is required when rejecting an employee."
SET MARTIN_LIST = (SELECT '[' || $MARTIN_ID || ']');
CALL APP.SP_SET_EMPLOYEE_CHECK('treasurer@example.org', $NOV_REQ, 2, $MARTIN_LIST, 'REJECTED', NULL);

-- A7. Expected OK: "1 employee check(s) set to REJECTED."
CALL APP.SP_SET_EMPLOYEE_CHECK('treasurer@example.org', $NOV_REQ, 2, $MARTIN_LIST, 'REJECTED', 'Bank account changed?');

-- A8. Expected ERROR: "3 employee(s) are not checked yet for this step."
CALL APP.SP_APPROVE_STEP('treasurer@example.org', $NOV_REQ, 2, NULL);

-- A9. Undo step 1, then approve it again. Expected OK: "Approval of step 1 undone." then "Step 1 approved."
CALL APP.SP_UNDO_APPROVAL('hr@example.org', $NOV_REQ, 1);
CALL APP.SP_APPROVE_STEP('hr@example.org', $NOV_REQ, 1, 'Approved again');

-- A10. The treasurer rejects step 2. Expected OK: "Sent back to step 1 for re-checking."
CALL APP.SP_REJECT_STEP('treasurer@example.org', $NOV_REQ, 2, 'Martin overtime looks wrong, please re-check');

-- A11. Expected: step 1 PENDING and next (latest action SEND_BACK), step 2 REJECTED
SELECT STEP_ORDER, STEP_TITLE, STEP_STATUS, ACTED_BY, ACTION_COMMENT, IS_NEXT_STEP
FROM RPT.V_F_APPROVAL_PROGRESS WHERE REQUEST_ID = $NOV_REQ ORDER BY STEP_ORDER;

-- A12. HR rejects step 1 too. Expected OK: "Sent back to the preparer. The payroll month is open for corrections."
CALL APP.SP_REJECT_STEP('hr@example.org', $NOV_REQ, 1, 'Needs a correction to Martin overtime');

-- A13. Expected: the same request is still IN_PROGRESS and November is OPEN
SELECT r.REQUEST_ID, r.REQUEST_STATUS, p.PERIOD_STATUS
FROM APP.T_F_APPROVAL_REQUEST r
JOIN APP.T_F_SCENARIO_PERIOD p ON p.SCENARIO_ID = r.SCENARIO_ID AND p.PERIOD_KEY = r.PERIOD_KEY
WHERE r.REQUEST_ID = $NOV_REQ;


/* =====================================================================================
   B. SETTINGS
   ===================================================================================== */

-- B1. Expected OK: "Exchange rates saved for 202611; payroll recalculated."
CALL APP.SP_SAVE_EXCHANGE_RATE('admin@example.org', 202611, 4090, 4050);

-- B2. Expected ERROR: "Month 202610 is finalized; its rates cannot change."
CALL APP.SP_SAVE_EXCHANGE_RATE('admin@example.org', 202610, 4000, 4000);

-- B3. Expected OK: "1 month(s) saved in the actual calendar."
CALL APP.SP_SAVE_WORKING_DAYS('admin@example.org', 'ACTUAL', '[{"period_key": 202612, "working_days": 21}]');

-- B4. Expected ERROR: "1 of the changed months are finalized and cannot change."
CALL APP.SP_SAVE_WORKING_DAYS('admin@example.org', 'ACTUAL', '[{"period_key": 202610, "working_days": 20}]');

-- B5. Rename step 2 and give it a new approver. Expected OK: "1 approval step(s) saved."
CALL APP.SP_SAVE_APPROVAL_STEPS('admin@example.org',
    '[{"step_order": 2, "step_title": "Finance Treasurer", "approver_email": "treasurer2@example.org", "approver_name": "New Treasurer"}]');

-- B6. Expected: only treasurer2@example.org holds TREASURER; step 2 has a new version titled "Finance Treasurer"
SELECT USER_EMAIL, ROLE_CODE FROM APP.T_D_APP_USER_ROLE ORDER BY ROLE_CODE, USER_EMAIL;
SELECT STEP_ORDER, STEP_TITLE, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY FROM CORE.T_P_APPROVAL_STEP ORDER BY STEP_ORDER, VALID_FROM_PERIOD_KEY;


/* =====================================================================================
   C. EMPLOYEES, COST CENTER, ADJUSTMENTS (November is open)
   ===================================================================================== */

-- C1. New employee starting in November. Expected OK: "Employee HR-KH-010 created."
CALL APP.SP_SAVE_EMPLOYEE('admin@example.org',
    '{"resource_code": "HR-KH-010", "first_name": "Lina", "last_name": "PEN", "entity_code": "ECCC",
      "monthly_salary_usd": 800, "employment_start_date": "2026-11-01", "dependant_children": 1}');

-- C2. Expected ERROR: "Resource ID HR-KH-010 is already used by another employee."
CALL APP.SP_SAVE_EMPLOYEE('admin@example.org',
    '{"resource_code": "HR-KH-010", "first_name": "Other", "last_name": "PERSON", "entity_code": "ECCC",
      "monthly_salary_usd": 500, "employment_start_date": "2026-11-01"}');

SET LINA_ID = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = 'HR-KH-010');

-- C3. Fund split in days (November has 21). Expected OK: "Fund split saved."
CALL APP.SP_SAVE_FUND_ALLOCATION('admin@example.org', $ACTUAL_ID, 202611, $LINA_ID, '[{"fund_code": "ECCC", "days": 21}]');

-- C4. Expected ERROR: "The shares total 90%. They must total 100%."
CALL APP.SP_SAVE_DEPARTMENT_ALLOCATION('admin@example.org', $ACTUAL_ID, 202611, $LINA_ID,
    '[{"department_code": "ADMIN", "share_pct": 50}, {"department_code": "EVENTS", "share_pct": 40}]');

-- C5. Expected OK: "Department split saved."
CALL APP.SP_SAVE_DEPARTMENT_ALLOCATION('admin@example.org', $ACTUAL_ID, 202611, $LINA_ID,
    '[{"department_code": "ADMIN", "share_pct": 40}, {"department_code": "EVENTS", "share_pct": 60}]');

-- C6. Dara's raise to 700 from the open month. Expected OK: "Contract saved from 202611."
CALL APP.SP_SAVE_EMPLOYEE_CONTRACT('admin@example.org', $DARA_ID, NULL, '{"monthly_salary_usd": 700, "change_reason": "Annual raise"}');

-- C7. Expected ERROR: "Month 202610 is finalized. Pay changes must start after 202610."
CALL APP.SP_SAVE_EMPLOYEE_CONTRACT('admin@example.org', $DARA_ID, 202610, '{"monthly_salary_usd": 750}');

-- C8. Expected OK: "Employee deactivated from 202611 onwards."
CALL APP.SP_SET_EMPLOYEE_ACTIVE('admin@example.org', $MARTIN_ID, FALSE);

-- C9. Expected OK: "Adjustment added."
CALL APP.SP_SAVE_PAYROLL_ADJUSTMENT('admin@example.org', NULL, 202611, $DARA_ID, 15, 202610, 'October transport allowance missed');

-- C10. November summary. Expected: 3 employees (Sokha 1,100, Dara 700 + 15 adjustment, Lina 800);
--      Martin is gone because he was deactivated in C8
SELECT e.RESOURCE_CODE, s.GROSS_PAY_USD, s.SALARY_TAX_USD, s.NET_PAY_USD, s.EMPLOYER_COST_USD
FROM CORE.V_F_PAYROLL_SUMMARY s JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = s.EMPLOYEE_ID
WHERE s.SCENARIO_ID = $ACTUAL_ID AND s.PERIOD_KEY = 202611 ORDER BY e.RESOURCE_CODE;

-- C11. Dara's contract history. Expected: 202601-202610 at 650, then 202611 onwards at 700
SELECT CONTRACT_ID, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, MONTHLY_SALARY_USD, CHANGE_REASON
FROM APP.T_D_EMPLOYEE_CONTRACT WHERE EMPLOYEE_ID = $DARA_ID ORDER BY VALID_FROM_PERIOD_KEY;


/* =====================================================================================
   D. BUDGETS
   ===================================================================================== */

-- D1. Copy the Growth budget. Expected OK: "Scenario Budget 2027 Copy created with 4 employees."
CALL APP.SP_CREATE_SCENARIO('clerk@example.org', 'Budget 2027 Copy', NULL, $GROWTH_ID, 'Copy of Growth');
SET COPY_ID = (SELECT SCENARIO_ID FROM APP.T_D_SCENARIO WHERE SCENARIO_NAME = 'Budget 2027 Copy');

-- D2. Sokha +8% from May in the copy only. Expected OK: "1 employee(s) updated and the scenario recalculated."
SET SOKHA_RAISE = (SELECT '[{"employee_id": ' || $SOKHA_ID || ', "raise_pct": 8, "revaluation_period_key": 202705}]');
CALL APP.SP_SAVE_SCENARIO_EMPLOYEE('clerk@example.org', $COPY_ID, $SOKHA_RAISE);

-- D3. Expected: Growth keeps 10% from April; the copy has 8% from May (1,188.00)
SELECT s.SCENARIO_NAME, se.MONTHLY_SALARY_USD, se.RAISE_PCT, se.REVALUATION_PERIOD_KEY, se.FINAL_SALARY_USD
FROM APP.T_D_SCENARIO_EMPLOYEE se JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = se.SCENARIO_ID
WHERE se.EMPLOYEE_ID = $SOKHA_ID AND s.SCENARIO_ID IN ($GROWTH_ID, $COPY_ID);

-- D4. Add a planned analyst from September. Expected OK: "Planned hire saved."
CALL APP.SP_SAVE_PLANNED_HIRE('clerk@example.org', $COPY_ID,
    '{"first_name": "Planned", "last_name": "Analyst", "entity_code": "CCIFC", "monthly_salary_usd": 900, "start_period_key": 202709}');
SET ANALYST_ID = (SELECT EMPLOYEE_ID FROM APP.T_D_EMPLOYEE WHERE PLANNED_SCENARIO_ID = $COPY_ID AND LAST_NAME = 'Analyst');

-- D5. Expected ERROR: "Only planned hires of this scenario can be removed. Actual employees cannot be deleted."
CALL APP.SP_DELETE_PLANNED_HIRE('clerk@example.org', $COPY_ID, $SOKHA_ID);

-- D6. Expected OK: "Planned hire removed."
CALL APP.SP_DELETE_PLANNED_HIRE('clerk@example.org', $COPY_ID, $ANALYST_ID);

-- D7. Expected OK: "Scenario submitted for approval."
CALL APP.SP_SUBMIT_SCENARIO('clerk@example.org', $COPY_ID);
SET COPY_REQ = (SELECT MAX(REQUEST_ID) FROM APP.T_F_APPROVAL_REQUEST WHERE SCENARIO_ID = $COPY_ID);

-- D8. Expected ERROR: "This scenario is IN_APPROVAL and cannot be edited."
CALL APP.SP_SAVE_SCENARIO_EMPLOYEE('clerk@example.org', $COPY_ID, $SOKHA_RAISE);

-- D9. Three approvals (step 2 now belongs to treasurer2, see B5).
--     Expected OK x3; the last: "Budget approved. It is now the official budget for 2027."
CALL APP.SP_APPROVE_STEP('hr@example.org',         $COPY_REQ, 1, NULL);
CALL APP.SP_APPROVE_STEP('treasurer2@example.org', $COPY_REQ, 2, NULL);
CALL APP.SP_APPROVE_STEP('director@example.org',   $COPY_REQ, 3, 'Approved');

-- D10. Expected: Copy APPROVED and official; Base no longer official
SELECT SCENARIO_NAME, SCENARIO_STATUS, IS_OFFICIAL FROM APP.T_D_SCENARIO WHERE SCENARIO_TYPE = 'BUDGET' ORDER BY SCENARIO_ID;

-- D11. Expected ERROR: "This is the official budget and cannot be deleted."
CALL APP.SP_DELETE_SCENARIO('clerk@example.org', $COPY_ID);

-- D12. Expected OK: "Scenario Budget 2027 Growth deleted." (its planned intern goes with it)
CALL APP.SP_DELETE_SCENARIO('clerk@example.org', $GROWTH_ID);


/* =====================================================================================
   E. FORECASTS
   ===================================================================================== */

-- E1. Expected ERROR: "A scenario named Forecast 2026 Q3 already exists. ..." (it is in the dummy data)
CALL APP.SP_CREATE_FORECAST('clerk@example.org', 2026, 3, NULL);

-- E2. Expected OK: "Forecast 2026 Q3 v2 created from 202609 for 3 employees."
CALL APP.SP_CREATE_FORECAST('clerk@example.org', 2026, 3, 'Forecast 2026 Q3 v2');

-- E3. Expected ERROR: "Give a fiscal year and a quarter from 1 to 3."
CALL APP.SP_CREATE_FORECAST('clerk@example.org', 2026, 4, NULL);

-- E4. Expected: months 202610-202612 for the new forecast, 3 employees each
SELECT s.SCENARIO_NAME, v.PERIOD_KEY, v.HEADCOUNT, v.GROSS_PAY_USD, v.EMPLOYER_COST_USD
FROM RPT.V_F_SCENARIO_SUMMARY v JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = v.SCENARIO_ID
WHERE s.SCENARIO_NAME = 'Forecast 2026 Q3 v2' ORDER BY v.PERIOD_KEY, v.ENTITY_CODE;

-- End of script
