CREATE OR REPLACE PROCEDURE APP.SP_CALC_PERIOD(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Internal: calculates the pay lines of one scenario period'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_status     TEXT;
    v_params     INT;
    v_brackets   INT;
    v_calc_id    TEXT;
    v_lines      INT DEFAULT 0;
    e_missing    EXCEPTION (-20001, 'Calculation refused: the period does not exist in this scenario.');
    e_locked     EXCEPTION (-20002, 'Calculation refused: the period is finalized or locked.');
    e_params     EXCEPTION (-20003, 'Calculation refused: statutory parameters or tax brackets are missing for the period.');
BEGIN
    SELECT MAX(PERIOD_STATUS) INTO :v_status
    FROM APP.T_F_SCENARIO_PERIOD
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY;

    IF (v_status IS NULL) THEN RAISE e_missing; END IF;
    IF (v_status = 'FINALIZED' OR v_status = 'LOCKED') THEN RAISE e_locked; END IF;

    SELECT COUNT(DISTINCT PARAM_CODE) INTO :v_params
    FROM APP.T_P_STATUTORY_PARAMETER
    WHERE :P_PERIOD_KEY BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912)
      AND PARAM_CODE IN ('NSSF_EE_PENSION_RATE', 'NSSF_ER_PENSION_RATE', 'NSSF_HEALTH_RATE', 'NSSF_ORC_RATE',
                         'NSSF_BASE_FLOOR_KHR', 'NSSF_BASE_CAP_KHR', 'DEPENDANT_ALLOWANCE_KHR',
                         'TAX_NON_RESIDENT_RATE', 'SENIORITY_TAX_EXEMPT_KHR', 'SENIORITY_DAYS_PER_PAYMENT',
                         'OVERTIME_MULTIPLIER');
    SELECT COUNT(*) INTO :v_brackets
    FROM APP.T_P_TAX_BRACKET
    WHERE :P_PERIOD_KEY BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    IF (v_params < 11 OR v_brackets = 0) THEN RAISE e_params; END IF;

    v_calc_id := 'CALC-' || P_SCENARIO_ID || '-' || P_PERIOD_KEY || '-' || UUID_STRING();

    DELETE FROM APP.T_F_PAYROLL_LINE
    WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY;

    INSERT INTO APP.T_F_PAYROLL_LINE
        (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, PAY_COMPONENT_CODE, EMPLOYEE_VERSION_KEY, ENTITY_CODE,
         QUANTITY, RATE, AMOUNT_USD, AMOUNT_KHR, FX_RATE_APPLIED, CALCULATION_ID, INSERT_BY, UPDATE_BY)
    WITH
    sp AS (      -- the scenario period being calculated
        SELECT s.SCENARIO_ID, s.SCENARIO_TYPE, s.FORECAST_AS_OF_PERIOD_KEY,
               x.PERIOD_KEY, x.WORKING_DAYS, x.FX_RATE_NBC, x.FX_RATE_NSSF,
               p.YEAR, p.HALF_YEAR, p.IS_SENIORITY_MONTH
        FROM APP.T_F_SCENARIO_PERIOD x
        JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID
        JOIN APP.T_D_PERIOD p  ON p.PERIOD_KEY = x.PERIOD_KEY
        WHERE x.SCENARIO_ID = :P_SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    ),
    prm AS (     -- statutory parameters valid for the period, as one row
        SELECT
            MAX(IFF(PARAM_CODE = 'NSSF_EE_PENSION_RATE',       PARAM_VALUE, NULL)) AS EE_RATE,
            MAX(IFF(PARAM_CODE = 'NSSF_ER_PENSION_RATE',       PARAM_VALUE, NULL)) AS ER_RATE,
            MAX(IFF(PARAM_CODE = 'NSSF_HEALTH_RATE',           PARAM_VALUE, NULL)) AS HEALTH_RATE,
            MAX(IFF(PARAM_CODE = 'NSSF_ORC_RATE',              PARAM_VALUE, NULL)) AS ORC_RATE,
            MAX(IFF(PARAM_CODE = 'NSSF_BASE_FLOOR_KHR',        PARAM_VALUE, NULL)) AS NSSF_FLOOR,
            MAX(IFF(PARAM_CODE = 'NSSF_BASE_CAP_KHR',          PARAM_VALUE, NULL)) AS NSSF_CAP,
            MAX(IFF(PARAM_CODE = 'DEPENDANT_ALLOWANCE_KHR',    PARAM_VALUE, NULL)) AS DEP_ALLOW,
            MAX(IFF(PARAM_CODE = 'TAX_NON_RESIDENT_RATE',      PARAM_VALUE, NULL)) AS NONRES_RATE,
            MAX(IFF(PARAM_CODE = 'SENIORITY_TAX_EXEMPT_KHR',   PARAM_VALUE, NULL)) AS SEN_EXEMPT,
            MAX(IFF(PARAM_CODE = 'SENIORITY_DAYS_PER_PAYMENT', PARAM_VALUE, NULL)) AS SEN_DAYS,
            MAX(IFF(PARAM_CODE = 'OVERTIME_MULTIPLIER',        PARAM_VALUE, NULL)) AS OT_MULT
        FROM APP.T_P_STATUTORY_PARAMETER
        WHERE :P_PERIOD_KEY BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912)
    ),
    terms AS (   -- employee terms: contracts for ACTUAL, scenario employees otherwise
        SELECT c.EMPLOYEE_ID, c.CONTRACT_ID AS VERSION_KEY, c.ENTITY_CODE,
               c.MONTHLY_SALARY_USD AS SALARY, c.TAX_STATUS, c.CONTRACT_TYPE,
               c.DEPENDANT_CHILDREN + c.DEPENDANT_SPOUSE AS DEPENDANTS,
               c.INSURANCE_USD, c.VISA_USD, c.WORK_PERMIT_USD, c.FRINGE_BENEFIT_USD
        FROM APP.T_D_EMPLOYEE_CONTRACT c
        JOIN sp ON sp.SCENARIO_TYPE = 'ACTUAL'
               AND sp.PERIOD_KEY BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912)
        UNION ALL
        SELECT se.EMPLOYEE_ID, COALESCE(se.SOURCE_CONTRACT_ID, -1), se.ENTITY_CODE,
               IFF(se.REVALUATION_PERIOD_KEY IS NOT NULL AND sp.PERIOD_KEY >= se.REVALUATION_PERIOD_KEY,
                   se.FINAL_SALARY_USD, se.MONTHLY_SALARY_USD),
               se.TAX_STATUS, se.CONTRACT_TYPE, se.DEPENDANT_CHILDREN + se.DEPENDANT_SPOUSE,
               se.INSURANCE_USD, se.VISA_USD, se.WORK_PERMIT_USD, se.FRINGE_BENEFIT_USD
        FROM APP.T_D_SCENARIO_EMPLOYEE se
        JOIN sp ON sp.SCENARIO_ID = se.SCENARIO_ID AND sp.SCENARIO_TYPE <> 'ACTUAL'
    ),
    inp AS (     -- who is paid this period, and their monthly inputs
        -- ACTUAL: exactly the input rows created when the period was opened
        SELECT i.EMPLOYEE_ID, i.ABSENCE_DAYS, i.OVERTIME_DAYS, i.OUTSTANDING_DAYS, i.BONUS_USD,
               i.SALARY_OVERRIDE_USD, i.FRINGE_BENEFIT_OVERRIDE_USD
        FROM APP.T_F_PAYROLL_INPUT i
        JOIN sp ON sp.SCENARIO_TYPE = 'ACTUAL' AND i.SCENARIO_ID = sp.SCENARIO_ID AND i.PERIOD_KEY = sp.PERIOD_KEY
        WHERE i.INCLUDE_IN_PAYROLL
        UNION ALL
        -- BUDGET / FORECAST: every scenario employee, unless excluded for the month
        SELECT se.EMPLOYEE_ID, COALESCE(i.ABSENCE_DAYS, 0), COALESCE(i.OVERTIME_DAYS, 0),
               COALESCE(i.OUTSTANDING_DAYS, 0), COALESCE(i.BONUS_USD, 0),
               i.SALARY_OVERRIDE_USD, i.FRINGE_BENEFIT_OVERRIDE_USD
        FROM APP.T_D_SCENARIO_EMPLOYEE se
        JOIN sp ON sp.SCENARIO_ID = se.SCENARIO_ID AND sp.SCENARIO_TYPE <> 'ACTUAL'
        LEFT JOIN APP.T_F_PAYROLL_INPUT i
               ON i.SCENARIO_ID = se.SCENARIO_ID AND i.PERIOD_KEY = sp.PERIOD_KEY AND i.EMPLOYEE_ID = se.EMPLOYEE_ID
        WHERE COALESCE(i.INCLUDE_IN_PAYROLL, TRUE)
    ),
    sen_hist AS (   -- salary + bonus of earlier months in the same half-year (seniority months only)
        SELECT l.EMPLOYEE_ID, SUM(l.AMOUNT_USD) AS PRIOR_USD, COUNT(DISTINCT l.PERIOD_KEY) AS PRIOR_MONTHS
        FROM APP.T_F_PAYROLL_LINE l
        JOIN APP.T_D_PERIOD p   ON p.PERIOD_KEY = l.PERIOD_KEY
        JOIN APP.T_D_SCENARIO ls ON ls.SCENARIO_ID = l.SCENARIO_ID
        JOIN sp                  ON p.YEAR = sp.YEAR AND p.HALF_YEAR = sp.HALF_YEAR
        WHERE sp.IS_SENIORITY_MONTH
          AND l.PERIOD_KEY < sp.PERIOD_KEY
          AND l.PAY_COMPONENT_CODE IN ('BASE_SALARY', 'BONUS')
          AND (   l.SCENARIO_ID = sp.SCENARIO_ID
               OR (sp.SCENARIO_TYPE = 'FORECAST' AND ls.SCENARIO_TYPE = 'ACTUAL'
                   AND l.PERIOD_KEY <= sp.FORECAST_AS_OF_PERIOD_KEY))
        GROUP BY l.EMPLOYEE_ID
    ),
    calc AS (    -- all amounts per employee
        SELECT
            i.EMPLOYEE_ID, t.VERSION_KEY, t.ENTITY_CODE, t.TAX_STATUS, t.DEPENDANTS,
            sp.WORKING_DAYS                                     AS WD,
            sp.FX_RATE_NBC                                      AS NBC,
            sp.FX_RATE_NSSF                                     AS NSSF,
            prm.EE_RATE, prm.ER_RATE, prm.HEALTH_RATE, prm.ORC_RATE, prm.DEP_ALLOW, prm.NONRES_RATE, prm.OT_MULT,
            i.ABSENCE_DAYS                                      AS ABS_DAYS,
            i.OVERTIME_DAYS                                     AS OT_DAYS,
            i.OUTSTANDING_DAYS                                  AS OUT_DAYS,
            -- USD earnings (unrounded)
            COALESCE(i.SALARY_OVERRIDE_USD, t.SALARY)           AS SAL,
            SAL / NULLIF(WD, 0)                                 AS DAILY,
            DAILY * ABS_DAYS                                    AS UNPAID,
            DAILY * OT_DAYS * prm.OT_MULT                       AS OT,
            DAILY * OUT_DAYS                                    AS OUTST,
            i.BONUS_USD                                         AS BONUS,
            IFF(sp.IS_SENIORITY_MONTH AND COALESCE(t.CONTRACT_TYPE, 'UDC') <> 'FDC',
                (COALESCE(h.PRIOR_USD, 0) + SAL + BONUS) / (COALESCE(h.PRIOR_MONTHS, 0) + 1)
                    / NULLIF(WD, 0) * prm.SEN_DAYS,
                0)                                              AS SEN,
            t.INSURANCE_USD                                     AS INS,
            t.VISA_USD                                          AS VISA,
            t.WORK_PERMIT_USD                                   AS WP,
            COALESCE(i.FRINGE_BENEFIT_OVERRIDE_USD, t.FRINGE_BENEFIT_USD) AS FRINGE,
            -- KHR earnings (converted from unrounded USD)
            ROUND(SAL * NBC)                                    AS SAL_KHR,
            ROUND(UNPAID * NBC)                                 AS UNPAID_KHR,
            ROUND(OT * NBC)                                     AS OT_KHR,
            ROUND(OUTST * NBC)                                  AS OUT_KHR,
            ROUND(BONUS * NBC)                                  AS BONUS_KHR,
            ROUND(SEN * NBC)                                    AS SEN_KHR,
            GREATEST(SEN_KHR - prm.SEN_EXEMPT, 0)               AS SEN_TAXABLE_KHR,
            -- NSSF (KHR)
            LEAST(GREATEST(ROUND((SAL + SEN) * NSSF), prm.NSSF_FLOOR), prm.NSSF_CAP) AS NSSF_BASE_KHR,
            ROUND(NSSF_BASE_KHR * prm.EE_RATE)                  AS EE_KHR,
            ROUND(NSSF_BASE_KHR * prm.ER_RATE)                  AS ERP_KHR,
            ROUND(NSSF_BASE_KHR * prm.HEALTH_RATE)              AS ERH_KHR,
            ROUND(NSSF_BASE_KHR * prm.ORC_RATE)                 AS ERO_KHR,
            -- Tax base (KHR)
            SAL_KHR - UNPAID_KHR + OT_KHR + OUT_KHR + BONUS_KHR + SEN_TAXABLE_KHR - EE_KHR AS TAXABLE_KHR,
            IFF(t.TAX_STATUS = 'RESIDENT', t.DEPENDANTS * prm.DEP_ALLOW, 0) AS RELIEF_KHR,
            GREATEST(TAXABLE_KHR - RELIEF_KHR, 0)               AS TAX_BASE_KHR
        FROM inp i
        JOIN terms t ON t.EMPLOYEE_ID = i.EMPLOYEE_ID
        CROSS JOIN sp
        CROSS JOIN prm
        LEFT JOIN sen_hist h ON h.EMPLOYEE_ID = i.EMPLOYEE_ID
    ),
    tax AS (     -- salary tax (KHR)
        SELECT c.*,
               IFF(c.TAX_STATUS = 'RESIDENT', COALESCE(b.TAX_RATE, 0), c.NONRES_RATE) AS APPLIED_TAX_RATE,
               IFF(c.TAX_STATUS = 'RESIDENT',
                   GREATEST(ROUND(c.TAX_BASE_KHR * COALESCE(b.TAX_RATE, 0) - COALESCE(b.CUMULATIVE_DEDUCTION_KHR, 0)), 0),
                   GREATEST(ROUND(c.TAX_BASE_KHR * c.NONRES_RATE), 0))                AS TAX_KHR
        FROM calc c
        LEFT JOIN APP.T_P_TAX_BRACKET b
               ON c.TAX_STATUS = 'RESIDENT'
              AND :P_PERIOD_KEY BETWEEN b.VALID_FROM_PERIOD_KEY AND COALESCE(b.VALID_TO_PERIOD_KEY, 999912)
              AND c.TAX_BASE_KHR > b.LOWER_BOUND_KHR
              AND (b.UPPER_BOUND_KHR IS NULL OR c.TAX_BASE_KHR <= b.UPPER_BOUND_KHR)
    ),
    lines AS (   -- one row per pay component (c = code, q = quantity, r = rate, u = USD, k = KHR, fx)
        SELECT t.EMPLOYEE_ID, t.VERSION_KEY, t.ENTITY_CODE, f.VALUE AS V
        FROM tax t,
        LATERAL FLATTEN(INPUT => ARRAY_CONSTRUCT(
            OBJECT_CONSTRUCT('c','BASE_SALARY',                                    'u', ROUND(t.SAL, 2),    'k', t.SAL_KHR,     'fx', t.NBC),
            OBJECT_CONSTRUCT('c','UNPAID_LEAVE',     'q', t.ABS_DAYS, 'r', t.DAILY, 'u', -ROUND(t.UNPAID, 2), 'k', -t.UNPAID_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','OVERTIME',         'q', t.OT_DAYS,  'r', t.DAILY * t.OT_MULT, 'u', ROUND(t.OT, 2), 'k', t.OT_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','OUTSTANDING_LEAVE','q', t.OUT_DAYS, 'r', t.DAILY, 'u', ROUND(t.OUTST, 2),  'k', t.OUT_KHR,     'fx', t.NBC),
            OBJECT_CONSTRUCT('c','BONUS',                                          'u', ROUND(t.BONUS, 2),  'k', t.BONUS_KHR,   'fx', t.NBC),
            OBJECT_CONSTRUCT('c','SENIORITY',                                      'u', ROUND(t.SEN, 2),    'k', t.SEN_KHR,     'fx', t.NBC),
            OBJECT_CONSTRUCT('c','NSSF_BASE',                                      'u', ROUND(t.NSSF_BASE_KHR / t.NSSF, 2), 'k', t.NSSF_BASE_KHR, 'fx', t.NSSF),
            OBJECT_CONSTRUCT('c','NSSF_EE_PENSION',  'r', t.EE_RATE,               'u', ROUND(t.EE_KHR  / t.NBC, 2), 'k', t.EE_KHR,  'fx', t.NBC),
            OBJECT_CONSTRUCT('c','NSSF_ER_PENSION',  'r', t.ER_RATE,               'u', ROUND(t.ERP_KHR / t.NBC, 2), 'k', t.ERP_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','NSSF_ER_HEALTH',   'r', t.HEALTH_RATE,           'u', ROUND(t.ERH_KHR / t.NBC, 2), 'k', t.ERH_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','NSSF_ER_ORC',      'r', t.ORC_RATE,              'u', ROUND(t.ERO_KHR / t.NBC, 2), 'k', t.ERO_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','TAXABLE_BASE',                                   'u', ROUND(t.TAXABLE_KHR / t.NBC, 2), 'k', t.TAXABLE_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','DEPENDANT_RELIEF', 'q', t.DEPENDANTS, 'r', t.DEP_ALLOW, 'u', ROUND(t.RELIEF_KHR / t.NBC, 2), 'k', t.RELIEF_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','TAX_CALC_BASE',                                  'u', ROUND(t.TAX_BASE_KHR / t.NBC, 2), 'k', t.TAX_BASE_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','SALARY_TAX',       'r', t.APPLIED_TAX_RATE,      'u', ROUND(t.TAX_KHR / t.NBC, 2), 'k', t.TAX_KHR, 'fx', t.NBC),
            OBJECT_CONSTRUCT('c','INSURANCE',                                      'u', ROUND(t.INS, 2),    'k', ROUND(t.INS * t.NBC),    'fx', t.NBC),
            OBJECT_CONSTRUCT('c','VISA',                                           'u', ROUND(t.VISA, 2),   'k', ROUND(t.VISA * t.NBC),   'fx', t.NBC),
            OBJECT_CONSTRUCT('c','WORK_PERMIT',                                    'u', ROUND(t.WP, 2),     'k', ROUND(t.WP * t.NBC),     'fx', t.NBC),
            OBJECT_CONSTRUCT('c','FRINGE_BENEFIT',                                 'u', ROUND(t.FRINGE, 2), 'k', ROUND(t.FRINGE * t.NBC), 'fx', t.NBC)
        )) f
    )
    SELECT :P_SCENARIO_ID, :P_PERIOD_KEY, EMPLOYEE_ID, V:c::TEXT, VERSION_KEY, ENTITY_CODE,
           V:q::FLOAT, V:r::FLOAT, V:u::FLOAT, V:k::FLOAT, V:fx::FLOAT,
           :v_calc_id, :P_USER_EMAIL, :P_USER_EMAIL
    FROM lines
    WHERE V:c::TEXT = 'BASE_SALARY' OR COALESCE(V:k::FLOAT, 0) <> 0;

    v_lines := SQLROWCOUNT;

    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_lines || ' pay lines calculated for ' || P_PERIOD_KEY,
                            'calculation_id', v_calc_id);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_APPROVAL_STEPS(P_USER_EMAIL TEXT, P_STEPS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Renames approval steps and assigns approvers'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed INT;
    v_now     INT;
    v_prev    INT;
    v_rows    INT;
    v_bad     INT;
    v_steps   TEXT;   -- JSON array: each sent step with its current version
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    v_now := TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'));
    v_prev := TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, DATE_TRUNC('MONTH', CURRENT_DATE())), 'YYYYMM'));

    -- Each sent step with the version in force this month, checked, and kept in v_steps
    SELECT COUNT(*), COUNT_IF(APPROVAL_STEP_ID IS NULL OR (STEP_TITLE IS NULL AND APPROVER_EMAIL IS NULL)),
           TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
               'STEP_ORDER', STEP_ORDER, 'STEP_TITLE', STEP_TITLE, 'APPROVER_EMAIL', APPROVER_EMAIL,
               'APPROVER_NAME', APPROVER_NAME, 'APPROVAL_STEP_ID', APPROVAL_STEP_ID, 'OLD_TITLE', OLD_TITLE,
               'APPROVER_ROLE', APPROVER_ROLE, 'APPLIES_TO', APPLIES_TO,
               'VALID_FROM_PERIOD_KEY', VALID_FROM_PERIOD_KEY, 'MANAGES_EMPLOYEE_CHECKS', MANAGES_EMPLOYEE_CHECKS)))
      INTO :v_rows, :v_bad, :v_steps
    FROM (SELECT f.VALUE:step_order::INT AS STEP_ORDER,
                 NULLIF(TRIM(f.VALUE:step_title::TEXT), '') AS STEP_TITLE,
                 LOWER(NULLIF(TRIM(f.VALUE:approver_email::TEXT), '')) AS APPROVER_EMAIL,
                 NULLIF(TRIM(f.VALUE:approver_name::TEXT), '') AS APPROVER_NAME,
                 s.APPROVAL_STEP_ID, s.STEP_TITLE AS OLD_TITLE, s.APPROVER_ROLE, s.APPLIES_TO, s.VALID_FROM_PERIOD_KEY,
                 COALESCE(s.MANAGES_EMPLOYEE_CHECKS, FALSE) AS MANAGES_EMPLOYEE_CHECKS
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_STEPS))) f
          LEFT JOIN APP.T_P_APPROVAL_STEP s
                 ON s.STEP_ORDER = f.VALUE:step_order::INT AND s.IS_ACTIVE
                AND :v_now BETWEEN s.VALID_FROM_PERIOD_KEY AND COALESCE(s.VALID_TO_PERIOD_KEY, 999912));
    IF (v_rows = 0 OR v_bad > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs an existing step_order and a step_title or approver_email.');
    END IF;

    -- One role per user: one person cannot be the approver of two steps
    SELECT COUNT(*) INTO :v_bad
    FROM (SELECT VALUE:APPROVER_EMAIL::TEXT AS APPROVER_EMAIL
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_steps)))
          WHERE VALUE:APPROVER_EMAIL::TEXT IS NOT NULL
          GROUP BY 1 HAVING COUNT(DISTINCT VALUE:APPROVER_ROLE::TEXT) > 1);
    IF (v_bad > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The same person cannot be the approver of two steps (one role per user).');
    END IF;

    BEGIN TRANSACTION;

    -- Titles: correct a version that started this month; otherwise close it and add a new one
    UPDATE APP.T_P_APPROVAL_STEP s
    SET STEP_TITLE = t.VALUE:STEP_TITLE::TEXT, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_steps)))) t
    WHERE s.APPROVAL_STEP_ID = t.VALUE:APPROVAL_STEP_ID::INT AND t.VALUE:STEP_TITLE::TEXT IS NOT NULL
      AND t.VALUE:STEP_TITLE::TEXT <> t.VALUE:OLD_TITLE::TEXT AND t.VALUE:VALID_FROM_PERIOD_KEY::INT = :v_now;

    INSERT INTO APP.T_P_APPROVAL_STEP (STEP_ORDER, STEP_TITLE, APPROVER_ROLE, APPLIES_TO, VALID_FROM_PERIOD_KEY, IS_ACTIVE, MANAGES_EMPLOYEE_CHECKS, INSERT_BY, UPDATE_BY)
    SELECT VALUE:STEP_ORDER::INT, VALUE:STEP_TITLE::TEXT, VALUE:APPROVER_ROLE::TEXT, VALUE:APPLIES_TO::TEXT, :v_now, TRUE,
           VALUE:MANAGES_EMPLOYEE_CHECKS::BOOLEAN, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_steps)))
    WHERE VALUE:STEP_TITLE::TEXT IS NOT NULL AND VALUE:STEP_TITLE::TEXT <> VALUE:OLD_TITLE::TEXT
      AND VALUE:VALID_FROM_PERIOD_KEY::INT < :v_now;

    UPDATE APP.T_P_APPROVAL_STEP s
    SET VALID_TO_PERIOD_KEY = :v_prev, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_steps)))) t
    WHERE s.APPROVAL_STEP_ID = t.VALUE:APPROVAL_STEP_ID::INT AND t.VALUE:STEP_TITLE::TEXT IS NOT NULL
      AND t.VALUE:STEP_TITLE::TEXT <> t.VALUE:OLD_TITLE::TEXT AND t.VALUE:VALID_FROM_PERIOD_KEY::INT < :v_now;

    -- Approvers: the new approver gets the step's level (created if new); other holders keep theirs
    MERGE INTO APP.T_D_APP_USER u
    USING (SELECT VALUE:APPROVER_EMAIL::TEXT AS APPROVER_EMAIL, MAX(VALUE:APPROVER_NAME::TEXT) AS APPROVER_NAME,
                  MAX(VALUE:APPROVER_ROLE::TEXT) AS APPROVER_ROLE
           FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_steps)))
           WHERE VALUE:APPROVER_EMAIL::TEXT IS NOT NULL GROUP BY 1) t
       ON u.USER_EMAIL = t.APPROVER_EMAIL
    WHEN MATCHED THEN UPDATE SET
        ROLE_CODE = t.APPROVER_ROLE, IS_ACTIVE = TRUE,
        DISPLAY_NAME = COALESCE(t.APPROVER_NAME, u.DISPLAY_NAME),
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT (USER_EMAIL, DISPLAY_NAME, ROLE_CODE, INSERT_BY, UPDATE_BY)
        VALUES (t.APPROVER_EMAIL, COALESCE(t.APPROVER_NAME, t.APPROVER_EMAIL), t.APPROVER_ROLE, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_P_APPROVAL_STEP', OBJECT_CONSTRUCT('STEP_ORDER', VALUE:STEP_ORDER::INT), 'UPDATE',
           OBJECT_CONSTRUCT('STEP_TITLE', VALUE:OLD_TITLE::TEXT),
           OBJECT_CONSTRUCT('STEP_TITLE', VALUE:STEP_TITLE::TEXT, 'APPROVER_EMAIL', VALUE:APPROVER_EMAIL::TEXT),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_steps)));

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_rows || ' approval step(s) saved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_MONTHLY_INPUT(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_INPUTS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves monthly inputs for one scenario period'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_scen_status TEXT;
    v_status      TEXT;
    v_wd          INT;
    v_allowed     INT;
    v_rows        INT;
    v_bad         INT;
    v_dupes       INT;
    v_unknown     INT;
    v_overrides   INT;
    v_changed     INT;
    v_new         TEXT;   -- JSON array: one object per employee (EMPLOYEE_ID, ROW_EXISTS, CHANGED, OLD_VALUES, NEW_VALUES)
BEGIN
    -- Scenario and period
    SELECT MAX(s.SCENARIO_TYPE), MAX(s.SCENARIO_STATUS), MAX(x.PERIOD_STATUS), MAX(x.WORKING_DAYS)
      INTO :v_type, :v_scen_status, :v_status, :v_wd
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    IF (v_status IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' does not exist in this scenario.');
    END IF;

    -- Any active app user may do this (roles only limit approvals)
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    -- Editable?
    IF (v_type = 'ACTUAL' AND v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is ' || v_status || ' and cannot be edited.');
    END IF;
    IF (v_type <> 'ACTUAL' AND ((v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') OR v_status <> 'DRAFT')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    -- The incoming rows merged with the current values, checked, and kept in v_new
    SELECT COUNT(*),
           COUNT_IF(EMPLOYEE_ID IS NULL OR ABSENCE_DAYS < 0 OR OVERTIME_DAYS < 0 OR OUTSTANDING_DAYS < 0
                    OR BONUS_USD < 0 OR ABSENCE_DAYS > :v_wd
                    OR COALESCE(SALARY_OVERRIDE_USD, 0) < 0 OR COALESCE(FRINGE_BENEFIT_OVERRIDE_USD, 0) < 0),
           COUNT(*) - COUNT(DISTINCT EMPLOYEE_ID),
           COUNT_IF(SALARY_OVERRIDE_USD IS NOT NULL OR FRINGE_BENEFIT_OVERRIDE_USD IS NOT NULL),
           COUNT_IF(NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES),
           TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
               'EMPLOYEE_ID', EMPLOYEE_ID, 'ROW_EXISTS', ROW_EXISTS,
               'CHANGED', NOT ROW_EXISTS OR OLD_VALUES <> NEW_VALUES,
               'OLD_VALUES', OLD_VALUES, 'NEW_VALUES', NEW_VALUES)))
      INTO :v_rows, :v_bad, :v_dupes, :v_overrides, :v_changed, :v_new
    FROM (
        SELECT m.*,
               OBJECT_CONSTRUCT_KEEP_NULL(
                   'INCLUDE_IN_PAYROLL', INCLUDE_IN_PAYROLL, 'ABSENCE_DAYS', ABSENCE_DAYS,
                   'OVERTIME_DAYS', OVERTIME_DAYS, 'OUTSTANDING_DAYS', OUTSTANDING_DAYS,
                   'BONUS_USD', BONUS_USD, 'SALARY_OVERRIDE_USD', SALARY_OVERRIDE_USD,
                   'FRINGE_BENEFIT_OVERRIDE_USD', FRINGE_BENEFIT_OVERRIDE_USD, 'NOTES', NOTES) AS NEW_VALUES
        FROM (
            SELECT
                j.VALUE:employee_id::INT                                                           AS EMPLOYEE_ID,
                COALESCE(j.VALUE:include_in_payroll::BOOLEAN, t.INCLUDE_IN_PAYROLL, TRUE)          AS INCLUDE_IN_PAYROLL,
                COALESCE(j.VALUE:absence_days::FLOAT,     t.ABSENCE_DAYS, 0)                       AS ABSENCE_DAYS,
                COALESCE(j.VALUE:overtime_days::FLOAT,    t.OVERTIME_DAYS, 0)                      AS OVERTIME_DAYS,
                COALESCE(j.VALUE:outstanding_days::FLOAT, t.OUTSTANDING_DAYS, 0)                   AS OUTSTANDING_DAYS,
                COALESCE(j.VALUE:bonus_usd::FLOAT,        t.BONUS_USD, 0)                          AS BONUS_USD,
                IFF(IS_NULL_VALUE(j.VALUE:salary_override_usd), NULL,
                    COALESCE(j.VALUE:salary_override_usd::FLOAT, t.SALARY_OVERRIDE_USD))           AS SALARY_OVERRIDE_USD,
                IFF(IS_NULL_VALUE(j.VALUE:fringe_benefit_override_usd), NULL,
                    COALESCE(j.VALUE:fringe_benefit_override_usd::FLOAT, t.FRINGE_BENEFIT_OVERRIDE_USD)) AS FRINGE_BENEFIT_OVERRIDE_USD,
                COALESCE(j.VALUE:notes::TEXT, t.NOTES)                                             AS NOTES,
                t.EMPLOYEE_ID IS NOT NULL                                                          AS ROW_EXISTS,
                OBJECT_CONSTRUCT_KEEP_NULL(
                    'INCLUDE_IN_PAYROLL', t.INCLUDE_IN_PAYROLL, 'ABSENCE_DAYS', t.ABSENCE_DAYS,
                    'OVERTIME_DAYS', t.OVERTIME_DAYS, 'OUTSTANDING_DAYS', t.OUTSTANDING_DAYS,
                    'BONUS_USD', t.BONUS_USD, 'SALARY_OVERRIDE_USD', t.SALARY_OVERRIDE_USD,
                    'FRINGE_BENEFIT_OVERRIDE_USD', t.FRINGE_BENEFIT_OVERRIDE_USD, 'NOTES', t.NOTES)  AS OLD_VALUES
            FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_INPUTS))) j
            LEFT JOIN APP.T_F_PAYROLL_INPUT t
                   ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = :P_PERIOD_KEY
                  AND t.EMPLOYEE_ID = j.VALUE:employee_id::INT) m);

    IF (v_rows = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No input rows received.');
    END IF;
    IF (v_bad > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_bad || ' row(s) have a missing employee, a negative value, or more absence days than working days (' || v_wd || ').');
    END IF;
    IF (v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The same employee appears more than once.');
    END IF;
    IF (v_type = 'ACTUAL' AND v_overrides > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Salary and fringe overrides are only allowed in budgets and forecasts. Change the contract instead.');
    END IF;

    -- Employees must belong to the payroll: a valid contract (ACTUAL) or the scenario (BUDGET / FORECAST)
    SELECT COUNT(*) INTO :v_unknown
    FROM (SELECT VALUE:EMPLOYEE_ID::INT AS EMPLOYEE_ID FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) x
    WHERE (:v_type = 'ACTUAL' AND NOT EXISTS (
              SELECT 1 FROM APP.T_D_EMPLOYEE e
              JOIN APP.T_D_EMPLOYEE_CONTRACT c ON c.EMPLOYEE_ID = e.EMPLOYEE_ID
              WHERE e.EMPLOYEE_ID = x.EMPLOYEE_ID AND e.IS_ACTIVE AND NOT e.IS_PLANNED
                AND :P_PERIOD_KEY BETWEEN c.VALID_FROM_PERIOD_KEY AND COALESCE(c.VALID_TO_PERIOD_KEY, 999912)))
       OR (:v_type <> 'ACTUAL' AND NOT EXISTS (
              SELECT 1 FROM APP.T_D_SCENARIO_EMPLOYEE se
              WHERE se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = x.EMPLOYEE_ID));
    IF (v_unknown > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_unknown || ' employee(s) are not part of this payroll.');
    END IF;

    IF (v_changed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    BEGIN TRANSACTION;

    -- Audit first (old vs new), only for rows that actually change
    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_PAYROLL_INPUT',
           OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', VALUE:EMPLOYEE_ID::INT),
           IFF(VALUE:ROW_EXISTS::BOOLEAN, 'UPDATE', 'INSERT'),
           IFF(VALUE:ROW_EXISTS::BOOLEAN, VALUE:OLD_VALUES, NULL),
           VALUE:NEW_VALUES,
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))
    WHERE VALUE:CHANGED::BOOLEAN;

    MERGE INTO APP.T_F_PAYROLL_INPUT t
    USING (SELECT VALUE:EMPLOYEE_ID::INT                                AS EMPLOYEE_ID,
                  VALUE:NEW_VALUES:INCLUDE_IN_PAYROLL::BOOLEAN          AS INCLUDE_IN_PAYROLL,
                  VALUE:NEW_VALUES:ABSENCE_DAYS::FLOAT                  AS ABSENCE_DAYS,
                  VALUE:NEW_VALUES:OVERTIME_DAYS::FLOAT                 AS OVERTIME_DAYS,
                  VALUE:NEW_VALUES:OUTSTANDING_DAYS::FLOAT              AS OUTSTANDING_DAYS,
                  VALUE:NEW_VALUES:BONUS_USD::FLOAT                     AS BONUS_USD,
                  VALUE:NEW_VALUES:SALARY_OVERRIDE_USD::FLOAT           AS SALARY_OVERRIDE_USD,
                  VALUE:NEW_VALUES:FRINGE_BENEFIT_OVERRIDE_USD::FLOAT   AS FRINGE_BENEFIT_OVERRIDE_USD,
                  VALUE:NEW_VALUES:NOTES::TEXT                          AS NOTES
           FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))
           WHERE VALUE:CHANGED::BOOLEAN) s
       ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = :P_PERIOD_KEY AND t.EMPLOYEE_ID = s.EMPLOYEE_ID
    WHEN MATCHED THEN UPDATE SET
        INCLUDE_IN_PAYROLL          = s.INCLUDE_IN_PAYROLL,
        ABSENCE_DAYS                = s.ABSENCE_DAYS,
        OVERTIME_DAYS               = s.OVERTIME_DAYS,
        OUTSTANDING_DAYS            = s.OUTSTANDING_DAYS,
        BONUS_USD                   = s.BONUS_USD,
        SALARY_OVERRIDE_USD         = s.SALARY_OVERRIDE_USD,
        FRINGE_BENEFIT_OVERRIDE_USD = s.FRINGE_BENEFIT_OVERRIDE_USD,
        NOTES                       = s.NOTES,
        UPDATE_DATE                 = CURRENT_TIMESTAMP,
        UPDATE_BY                   = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT
        (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, ABSENCE_DAYS, OVERTIME_DAYS, OUTSTANDING_DAYS,
         BONUS_USD, SALARY_OVERRIDE_USD, FRINGE_BENEFIT_OVERRIDE_USD, NOTES, INSERT_BY, UPDATE_BY)
    VALUES
        (:P_SCENARIO_ID, :P_PERIOD_KEY, s.EMPLOYEE_ID, s.INCLUDE_IN_PAYROLL, s.ABSENCE_DAYS, s.OVERTIME_DAYS,
         s.OUTSTANDING_DAYS, s.BONUS_USD, s.SALARY_OVERRIDE_USD, s.FRINGE_BENEFIT_OVERRIDE_USD, s.NOTES,
         :P_USER_EMAIL, :P_USER_EMAIL);

    -- ACTUAL: numbers changed, so started approvals start over
    IF (v_type = 'ACTUAL') THEN
        -- Every approved step goes back to PENDING (logged first, while still APPROVED)
        INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
        SELECT 'APP.T_F_APPROVAL',
               OBJECT_CONSTRUCT('SCENARIO_ID', SCENARIO_ID, 'PERIOD_KEY', PERIOD_KEY, 'STEP_ORDER', STEP_ORDER), 'UPDATE',
               OBJECT_CONSTRUCT('STEP_STATUS', 'APPROVED'),
               OBJECT_CONSTRUCT('ACTION_TYPE', 'RESET', 'STEP_STATUS', 'PENDING', 'COMMENT', 'Monthly inputs changed'),
               :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
        FROM APP.T_F_APPROVAL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';

        UPDATE APP.T_F_APPROVAL
        SET STEP_STATUS = 'PENDING', LAST_ACTION = 'RESET', ACTED_BY = 'SYSTEM', ACTED_AT = CURRENT_TIMESTAMP,
            STEP_COMMENT = 'Monthly inputs changed by ' || :P_USER_EMAIL,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND STEP_STATUS = 'APPROVED';

        -- The changed employees must be checked again; an old rejection reason no longer applies
        UPDATE APP.T_F_PAYROLL_INPUT
        SET CHECK_STATUS = 'PENDING', CHECK_COMMENT = NULL, CHECKED_BY = NULL,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY
          AND COALESCE(CHECK_STATUS, 'PENDING') <> 'PENDING'
          AND EMPLOYEE_ID IN (SELECT VALUE:EMPLOYEE_ID::INT FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))
                              WHERE VALUE:CHANGED::BOOLEAN);

        UPDATE APP.T_F_SCENARIO_PERIOD
        SET PERIOD_STATUS = 'OPEN', UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND PERIOD_STATUS = 'IN_APPROVAL';
    END IF;

    CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY);

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' employee(s) updated and payroll recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_PLANNED_HIRE(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_HIRE TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Adds or edits a planned hire'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_emp         INT;
    v_found       INT;
    v_code        TEXT;
    v_first       INT;
    v_start       INT;
    v_end         INT;
    v_entity_ok   INT;
    v_pk          INT;
    -- The hire's terms
    v_first_name  TEXT;
    v_last_name   TEXT;
    v_position    TEXT;
    v_emp_type    TEXT;
    v_contract    TEXT;
    v_entity      TEXT;
    v_salary      FLOAT;
    v_raise       FLOAT;
    v_reval       INT;
    v_tax         TEXT;
    v_children    INT;
    v_spouse      INT;
    v_insurance   FLOAT;
    v_visa        FLOAT;
    v_permit      FLOAT;
    v_fringe      FLOAT;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;
    SELECT MAX(SCENARIO_TYPE), MAX(SCENARIO_STATUS) INTO :v_type, :v_scen_status
    FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL OR v_type = 'ACTUAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' is not a budget or forecast.');
    END IF;
    IF (v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    SELECT D:employee_id::INT INTO :v_emp FROM (SELECT PARSE_JSON(:P_HIRE) AS D);
    SELECT MIN(PERIOD_KEY) INTO :v_first FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :P_SCENARIO_ID;

    IF (v_emp IS NOT NULL) THEN
        SELECT COUNT(*) INTO :v_found FROM APP.T_D_EMPLOYEE
        WHERE EMPLOYEE_ID = :v_emp AND IS_PLANNED AND PLANNED_SCENARIO_ID = :P_SCENARIO_ID;
        IF (v_found = 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || v_emp || ' is not a planned hire of this scenario.');
        END IF;
        SELECT MIN(IFF(i.INCLUDE_IN_PAYROLL, x.PERIOD_KEY, NULL)), MAX(IFF(i.INCLUDE_IN_PAYROLL, x.PERIOD_KEY, NULL))
          INTO :v_start, :v_end
        FROM APP.T_F_SCENARIO_PERIOD x
        LEFT JOIN APP.T_F_PAYROLL_INPUT i ON i.SCENARIO_ID = x.SCENARIO_ID AND i.PERIOD_KEY = x.PERIOD_KEY AND i.EMPLOYEE_ID = :v_emp
        WHERE x.SCENARIO_ID = :P_SCENARIO_ID;
    END IF;

    SELECT COALESCE(D:start_period_key::INT, :v_start, :v_first),
           IFF(IS_NULL_VALUE(D:end_period_key), NULL, COALESCE(D:end_period_key::INT, :v_end))
      INTO :v_start, :v_end
    FROM (SELECT PARSE_JSON(:P_HIRE) AS D);

    -- The hire's terms (existing values overlaid with the JSON)
    SELECT
        COALESCE(x.D:first_name::TEXT, e.FIRST_NAME, 'New'),
        COALESCE(x.D:last_name::TEXT, e.LAST_NAME, 'Hire'),
        COALESCE(x.D:position::TEXT, se.POSITION),
        COALESCE(x.D:employment_type::TEXT, se.EMPLOYMENT_TYPE, 'FULL_TIME'),
        COALESCE(x.D:contract_type::TEXT, se.CONTRACT_TYPE),
        COALESCE(x.D:entity_code::TEXT, se.ENTITY_CODE),
        COALESCE(x.D:monthly_salary_usd::FLOAT, se.MONTHLY_SALARY_USD),
        COALESCE(x.D:raise_pct::FLOAT, se.RAISE_PCT, 0),
        IFF(IS_NULL_VALUE(x.D:revaluation_period_key), NULL,
            COALESCE(x.D:revaluation_period_key::INT, se.REVALUATION_PERIOD_KEY)),
        COALESCE(x.D:tax_status::TEXT, se.TAX_STATUS, 'RESIDENT'),
        COALESCE(x.D:dependant_children::INT, se.DEPENDANT_CHILDREN, 0),
        COALESCE(x.D:dependant_spouse::INT, se.DEPENDANT_SPOUSE, 0),
        COALESCE(x.D:insurance_usd::FLOAT, se.INSURANCE_USD, 0),
        COALESCE(x.D:visa_usd::FLOAT, se.VISA_USD, 0),
        COALESCE(x.D:work_permit_usd::FLOAT, se.WORK_PERMIT_USD, 0),
        COALESCE(x.D:fringe_benefit_usd::FLOAT, se.FRINGE_BENEFIT_USD, 0)
      INTO :v_first_name, :v_last_name, :v_position, :v_emp_type, :v_contract, :v_entity,
           :v_salary, :v_raise, :v_reval, :v_tax, :v_children, :v_spouse,
           :v_insurance, :v_visa, :v_permit, :v_fringe
    FROM (SELECT PARSE_JSON(:P_HIRE) AS D) x
    LEFT JOIN APP.T_D_EMPLOYEE e ON e.EMPLOYEE_ID = :v_emp
    LEFT JOIN APP.T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = :v_emp;

    SELECT COUNT(*) INTO :v_entity_ok FROM APP.T_D_ENTITY WHERE ENTITY_CODE = :v_entity AND IS_ACTIVE;
    IF (v_salary IS NULL OR v_salary < 0 OR v_entity_ok = 0 OR v_raise < -100
        OR (v_spouse <> 0 AND v_spouse <> 1) OR v_children < 0
        OR (v_tax <> 'RESIDENT' AND v_tax <> 'NON_RESIDENT')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'A planned hire needs a known chamber (entity_code), a salary >= 0 and valid tax details.');
    END IF;
    IF (v_end IS NOT NULL AND v_end < v_start) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The end month is before the start month.');
    END IF;

    BEGIN TRANSACTION;

    IF (v_emp IS NULL) THEN
        v_code := 'PLAN-' || P_SCENARIO_ID || '-' || UPPER(LEFT(REPLACE(UUID_STRING(), '-', ''), 8));
        INSERT INTO APP.T_D_EMPLOYEE (RESOURCE_CODE, FIRST_NAME, LAST_NAME, IS_ACTIVE, IS_PLANNED, PLANNED_SCENARIO_ID, INSERT_BY, UPDATE_BY)
        SELECT :v_code, :v_first_name, :v_last_name, TRUE, TRUE, :P_SCENARIO_ID, :P_USER_EMAIL, :P_USER_EMAIL;
        SELECT MAX(EMPLOYEE_ID) INTO :v_emp FROM APP.T_D_EMPLOYEE WHERE RESOURCE_CODE = :v_code;

        INSERT INTO APP.T_D_SCENARIO_EMPLOYEE
            (SCENARIO_ID, EMPLOYEE_ID, SOURCE_CONTRACT_ID, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, RAISE_PCT, REVALUATION_PERIOD_KEY, FINAL_SALARY_USD, TAX_STATUS,
             DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD, WORK_PERMIT_USD, FRINGE_BENEFIT_USD, INSERT_BY, UPDATE_BY)
        SELECT :P_SCENARIO_ID, :v_emp, NULL, :v_position, :v_emp_type, :v_contract, :v_entity,
               :v_salary, :v_raise, :v_reval, ROUND(:v_salary * (1 + :v_raise / 100), 2),
               :v_tax, :v_children, :v_spouse, :v_insurance, :v_visa, :v_permit, :v_fringe,
               :P_USER_EMAIL, :P_USER_EMAIL;
    ELSE
        UPDATE APP.T_D_EMPLOYEE
        SET FIRST_NAME = :v_first_name, LAST_NAME = :v_last_name, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE EMPLOYEE_ID = :v_emp;

        UPDATE APP.T_D_SCENARIO_EMPLOYEE
        SET POSITION = :v_position, EMPLOYMENT_TYPE = :v_emp_type, CONTRACT_TYPE = :v_contract,
            ENTITY_CODE = :v_entity, MONTHLY_SALARY_USD = :v_salary, RAISE_PCT = :v_raise,
            REVALUATION_PERIOD_KEY = :v_reval,
            FINAL_SALARY_USD = ROUND(:v_salary * (1 + :v_raise / 100), 2),
            TAX_STATUS = :v_tax, DEPENDANT_CHILDREN = :v_children, DEPENDANT_SPOUSE = :v_spouse,
            INSURANCE_USD = :v_insurance, VISA_USD = :v_visa, WORK_PERMIT_USD = :v_permit,
            FRINGE_BENEFIT_USD = :v_fringe, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :v_emp;
    END IF;

    -- Paid only between the start and end months
    MERGE INTO APP.T_F_PAYROLL_INPUT t
    USING (SELECT PERIOD_KEY, (PERIOD_KEY >= :v_start AND PERIOD_KEY <= COALESCE(:v_end, 999912)) AS INCLUDED
           FROM APP.T_F_SCENARIO_PERIOD WHERE SCENARIO_ID = :P_SCENARIO_ID) s
       ON t.SCENARIO_ID = :P_SCENARIO_ID AND t.PERIOD_KEY = s.PERIOD_KEY AND t.EMPLOYEE_ID = :v_emp
    WHEN MATCHED THEN UPDATE SET INCLUDE_IN_PAYROLL = s.INCLUDED, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    WHEN NOT MATCHED THEN INSERT (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, INCLUDE_IN_PAYROLL, INSERT_BY, UPDATE_BY)
        VALUES (:P_SCENARIO_ID, s.PERIOD_KEY, :v_emp, s.INCLUDED, :P_USER_EMAIL, :P_USER_EMAIL);

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO_EMPLOYEE', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'EMPLOYEE_ID', :v_emp), 'UPDATE', NULL, PARSE_JSON(:P_HIRE), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    LET rs_calc RESULTSET := (
        SELECT PERIOD_KEY FROM APP.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur_calc CURSOR FOR rs_calc;
    FOR rec IN cur_calc DO
        v_pk := rec.PERIOD_KEY;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
    END FOR;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Planned hire saved.', 'employee_id', v_emp);
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_SCENARIO_EMPLOYEE(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_EMPLOYEES TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Edits employee terms in a budget or forecast scenario'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed     INT;
    v_type        TEXT;
    v_scen_status TEXT;
    v_rows        INT;
    v_bad         INT;
    v_pk          INT;
    v_new         TEXT;   -- JSON array: one object per employee, new terms + OLD_VALUES
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;
    SELECT MAX(SCENARIO_TYPE), MAX(SCENARIO_STATUS) INTO :v_type, :v_scen_status
    FROM APP.T_D_SCENARIO WHERE SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL OR v_type = 'ACTUAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' is not a budget or forecast.');
    END IF;
    IF (v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    -- Each employee's new terms (current values overlaid with the JSON) and the old values for the log
    SELECT COUNT(*),
           TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
               'EMPLOYEE_ID',            f.VALUE:employee_id::INT,
               'IN_SCENARIO',            se.EMPLOYEE_ID IS NOT NULL,
               'MONTHLY_SALARY_USD',     COALESCE(f.VALUE:monthly_salary_usd::FLOAT, se.MONTHLY_SALARY_USD),
               'RAISE_PCT',              COALESCE(f.VALUE:raise_pct::FLOAT, se.RAISE_PCT, 0),
               'REVALUATION_PERIOD_KEY', IFF(IS_NULL_VALUE(f.VALUE:revaluation_period_key), NULL,
                                             COALESCE(f.VALUE:revaluation_period_key::INT, se.REVALUATION_PERIOD_KEY)),
               'FRINGE_BENEFIT_USD',     COALESCE(f.VALUE:fringe_benefit_usd::FLOAT, se.FRINGE_BENEFIT_USD),
               'POSITION',               COALESCE(f.VALUE:position::TEXT, se.POSITION),
               'EMPLOYMENT_TYPE',        COALESCE(f.VALUE:employment_type::TEXT, se.EMPLOYMENT_TYPE),
               'CONTRACT_TYPE',          COALESCE(f.VALUE:contract_type::TEXT, se.CONTRACT_TYPE),
               'ENTITY_CODE',            COALESCE(f.VALUE:entity_code::TEXT, se.ENTITY_CODE),
               'TAX_STATUS',             COALESCE(f.VALUE:tax_status::TEXT, se.TAX_STATUS),
               'DEPENDANT_CHILDREN',     COALESCE(f.VALUE:dependant_children::INT, se.DEPENDANT_CHILDREN),
               'DEPENDANT_SPOUSE',       COALESCE(f.VALUE:dependant_spouse::INT, se.DEPENDANT_SPOUSE),
               'INSURANCE_USD',          COALESCE(f.VALUE:insurance_usd::FLOAT, se.INSURANCE_USD),
               'VISA_USD',               COALESCE(f.VALUE:visa_usd::FLOAT, se.VISA_USD),
               'WORK_PERMIT_USD',        COALESCE(f.VALUE:work_permit_usd::FLOAT, se.WORK_PERMIT_USD),
               'OLD_VALUES', OBJECT_CONSTRUCT_KEEP_NULL('MONTHLY_SALARY_USD', se.MONTHLY_SALARY_USD, 'RAISE_PCT', se.RAISE_PCT,
                   'REVALUATION_PERIOD_KEY', se.REVALUATION_PERIOD_KEY, 'FINAL_SALARY_USD', se.FINAL_SALARY_USD,
                   'FRINGE_BENEFIT_USD', se.FRINGE_BENEFIT_USD, 'ENTITY_CODE', se.ENTITY_CODE))))
      INTO :v_rows, :v_new
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_EMPLOYEES))) f
    LEFT JOIN APP.T_D_SCENARIO_EMPLOYEE se
           ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = f.VALUE:employee_id::INT;

    SELECT COUNT_IF(NOT t.R:IN_SCENARIO::BOOLEAN OR t.R:MONTHLY_SALARY_USD::FLOAT < 0 OR t.R:RAISE_PCT::FLOAT < -100
                    OR t.R:FRINGE_BENEFIT_USD::FLOAT < 0 OR t.R:INSURANCE_USD::FLOAT < 0 OR t.R:VISA_USD::FLOAT < 0
                    OR t.R:WORK_PERMIT_USD::FLOAT < 0 OR t.R:DEPENDANT_CHILDREN::INT < 0
                    OR t.R:DEPENDANT_SPOUSE::INT NOT IN (0, 1) OR t.R:TAX_STATUS::TEXT NOT IN ('RESIDENT', 'NON_RESIDENT')
                    OR e.ENTITY_CODE IS NULL
                    OR (t.R:REVALUATION_PERIOD_KEY::INT IS NOT NULL AND x.PERIOD_KEY IS NULL))
      INTO :v_bad
    FROM (SELECT VALUE AS R FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    LEFT JOIN APP.T_D_ENTITY e ON e.ENTITY_CODE = t.R:ENTITY_CODE::TEXT AND e.IS_ACTIVE
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = :P_SCENARIO_ID AND x.PERIOD_KEY = t.R:REVALUATION_PERIOD_KEY::INT;
    IF (v_rows = 0 OR v_bad > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Invalid rows: employees must be in the scenario, amounts >= 0, raise >= -100%, a known chamber and a revaluation month inside the scenario.');
    END IF;

    BEGIN TRANSACTION;

    UPDATE APP.T_D_SCENARIO_EMPLOYEE se
    SET MONTHLY_SALARY_USD = t.R:MONTHLY_SALARY_USD::FLOAT, RAISE_PCT = t.R:RAISE_PCT::FLOAT,
        REVALUATION_PERIOD_KEY = t.R:REVALUATION_PERIOD_KEY::INT,
        FINAL_SALARY_USD = ROUND(t.R:MONTHLY_SALARY_USD::FLOAT * (1 + t.R:RAISE_PCT::FLOAT / 100), 2),
        FRINGE_BENEFIT_USD = t.R:FRINGE_BENEFIT_USD::FLOAT, POSITION = t.R:POSITION::TEXT,
        EMPLOYMENT_TYPE = t.R:EMPLOYMENT_TYPE::TEXT, CONTRACT_TYPE = t.R:CONTRACT_TYPE::TEXT,
        ENTITY_CODE = t.R:ENTITY_CODE::TEXT, TAX_STATUS = t.R:TAX_STATUS::TEXT,
        DEPENDANT_CHILDREN = t.R:DEPENDANT_CHILDREN::INT, DEPENDANT_SPOUSE = t.R:DEPENDANT_SPOUSE::INT,
        INSURANCE_USD = t.R:INSURANCE_USD::FLOAT, VISA_USD = t.R:VISA_USD::FLOAT, WORK_PERMIT_USD = t.R:WORK_PERMIT_USD::FLOAT,
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE AS R FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    WHERE se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = t.R:EMPLOYEE_ID::INT;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_SCENARIO_EMPLOYEE', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'EMPLOYEE_ID', se.EMPLOYEE_ID), 'UPDATE',
           t.R:OLD_VALUES,
           OBJECT_CONSTRUCT_KEEP_NULL('MONTHLY_SALARY_USD', se.MONTHLY_SALARY_USD, 'RAISE_PCT', se.RAISE_PCT,
                'REVALUATION_PERIOD_KEY', se.REVALUATION_PERIOD_KEY, 'FINAL_SALARY_USD', se.FINAL_SALARY_USD,
                'FRINGE_BENEFIT_USD', se.FRINGE_BENEFIT_USD, 'ENTITY_CODE', se.ENTITY_CODE),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM (SELECT VALUE AS R FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    JOIN APP.T_D_SCENARIO_EMPLOYEE se ON se.SCENARIO_ID = :P_SCENARIO_ID AND se.EMPLOYEE_ID = t.R:EMPLOYEE_ID::INT;

    LET rs_calc RESULTSET := (
        SELECT PERIOD_KEY FROM APP.T_F_SCENARIO_PERIOD
        WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_STATUS NOT IN ('FINALIZED', 'LOCKED')
        ORDER BY PERIOD_KEY);
    LET cur_calc CURSOR FOR rs_calc;
    FOR rec IN cur_calc DO
        v_pk := rec.PERIOD_KEY;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :v_pk);
    END FOR;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_rows || ' employee(s) updated and the scenario recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_DEPARTMENT_ALLOCATION(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_EMPLOYEE_ID INT, P_ALLOCATIONS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves the department split of one employee'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_scen_status TEXT;
    v_status      TEXT;
    v_wd          INT;
    v_allowed     INT;
    v_in_payroll  INT;
    v_rows        INT;
    v_bad         INT;
    v_dupes       INT;
    v_total       FLOAT;
    v_old         TEXT;
    v_new         TEXT;
    v_ids         TEXT;
BEGIN
    SELECT MAX(s.SCENARIO_TYPE), MAX(s.SCENARIO_STATUS), MAX(x.PERIOD_STATUS), MAX(x.WORKING_DAYS)
      INTO :v_type, :v_scen_status, :v_status, :v_wd
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    IF (v_status IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' does not exist in this scenario.');
    END IF;
    IF (v_type = 'ACTUAL' AND v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is ' || v_status || ' and cannot be edited.');
    END IF;
    IF (v_type <> 'ACTUAL' AND ((v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') OR v_status <> 'DRAFT')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*) INTO :v_in_payroll
    FROM (SELECT EMPLOYEE_ID FROM APP.T_F_PAYROLL_INPUT
          WHERE :v_type = 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID
          UNION
          SELECT EMPLOYEE_ID FROM APP.T_D_SCENARIO_EMPLOYEE
          WHERE :v_type <> 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID);
    IF (v_in_payroll = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' is not part of this payroll.');
    END IF;

    -- Checks, and the new split (rows with a share > 0) kept in v_new
    SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT t.CODE), COALESCE(SUM(t.SHARE_PCT), 0),
           COUNT_IF(t.CODE IS NULL OR t.SHARE_PCT IS NULL OR t.SHARE_PCT < 0 OR d.DEPARTMENT_CODE IS NULL),
           TO_JSON(ARRAY_AGG(IFF(t.SHARE_PCT > 0, OBJECT_CONSTRUCT('department_code', t.CODE, 'share_pct', t.SHARE_PCT), NULL)))
      INTO :v_rows, :v_dupes, :v_total, :v_bad, :v_new
    FROM (SELECT f.VALUE:department_code::TEXT AS CODE, f.VALUE:share_pct::FLOAT AS SHARE_PCT
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_ALLOCATIONS))) f) t
    LEFT JOIN APP.T_D_DEPARTMENT d ON d.DEPARTMENT_CODE = t.CODE AND d.IS_ACTIVE;
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs a known, active department code and a share >= 0, with no duplicates.');
    END IF;
    IF (ABS(v_total - 100) > 0.01) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The shares total ' || ROUND(v_total, 2) || '%. They must total 100%.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('department_code', DEPARTMENT_CODE, 'share_pct', SHARE_PCT))) INTO :v_old
    FROM APP.T_F_DEPARTMENT_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    DELETE FROM APP.T_F_DEPARTMENT_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    INSERT INTO APP.T_F_DEPARTMENT_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, DEPARTMENT_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :P_SCENARIO_ID, :P_PERIOD_KEY, :P_EMPLOYEE_ID, VALUE:department_code::TEXT, VALUE:share_pct::FLOAT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)));

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_DEPARTMENT_ALLOCATION', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', :P_EMPLOYEE_ID), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_type = 'ACTUAL') THEN
        v_ids := '[' || P_EMPLOYEE_ID || ']';
        CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY, :v_ids, 'Department split changed');
    END IF;
    CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY);

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Department split saved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_EMPLOYEE_CONTRACT(P_USER_EMAIL TEXT, P_EMPLOYEE_ID INT, P_EFFECTIVE_PERIOD_KEY INT, P_CONTRACT TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Adds or corrects an employee contract version'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed    INT;
    v_exists     INT;
    v_planned    BOOLEAN;
    v_actual     INT;
    v_open       INT;
    v_last_final INT;
    v_eff        INT;
    v_prev       INT;
    v_cur_id     INT;
    v_cur_from   INT;
    v_cur_to     INT;
    v_ids        TEXT;
    v_entity_ok  INT;
    v_old        TEXT;
    v_new        TEXT;
    -- The new terms
    v_position   TEXT;
    v_emp_type   TEXT;
    v_contract   TEXT;
    v_entity     TEXT;
    v_salary     FLOAT;
    v_tax        TEXT;
    v_children   INT;
    v_spouse     INT;
    v_insurance  FLOAT;
    v_visa       FLOAT;
    v_permit     FLOAT;
    v_fringe     FLOAT;
    v_reason     TEXT;
    v_nr_from    DATE;
    v_nr_to      DATE;
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*), MAX(IS_PLANNED) INTO :v_exists, :v_planned FROM APP.T_D_EMPLOYEE WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID;
    IF (v_exists = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' does not exist.');
    END IF;
    IF (v_planned) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Planned hires are edited on the Budget / Forecast pages.');
    END IF;

    SELECT MAX(s.SCENARIO_ID), MAX(IFF(x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'), x.PERIOD_KEY, NULL)),
           MAX(IFF(x.PERIOD_STATUS = 'FINALIZED', x.PERIOD_KEY, NULL))
      INTO :v_actual, :v_open, :v_last_final
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID
    WHERE s.SCENARIO_TYPE = 'ACTUAL';

    v_eff := COALESCE(P_EFFECTIVE_PERIOD_KEY, v_open);
    IF (v_eff IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'No payroll month is open; give the effective month.');
    END IF;
    IF (v_eff <= COALESCE(v_last_final, 0)) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || v_eff || ' is finalized. Pay changes must start after ' || v_last_final || '.');
    END IF;

    SELECT MAX(TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, PERIOD_START_DATE), 'YYYYMM'))) INTO :v_prev
    FROM APP.T_D_PERIOD WHERE PERIOD_KEY = :v_eff;
    IF (v_prev IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || v_eff || ' is not in the calendar.');
    END IF;

    SELECT MAX(CONTRACT_ID), MAX(VALID_FROM_PERIOD_KEY), MAX(VALID_TO_PERIOD_KEY) INTO :v_cur_id, :v_cur_from, :v_cur_to
    FROM APP.T_D_EMPLOYEE_CONTRACT
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID
      AND :v_eff BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    IF (v_cur_id IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The employee has no contract in force in ' || v_eff || '. Create one with SP_SAVE_EMPLOYEE.');
    END IF;

    -- New terms = current version overlaid with the JSON
    SELECT
        COALESCE(x.D:position::TEXT,           c.POSITION),
        COALESCE(x.D:employment_type::TEXT,    c.EMPLOYMENT_TYPE),
        COALESCE(x.D:contract_type::TEXT,      c.CONTRACT_TYPE),
        COALESCE(x.D:entity_code::TEXT,        c.ENTITY_CODE),
        COALESCE(x.D:monthly_salary_usd::FLOAT, c.MONTHLY_SALARY_USD),
        COALESCE(x.D:tax_status::TEXT,         c.TAX_STATUS),
        COALESCE(x.D:dependant_children::INT,  c.DEPENDANT_CHILDREN),
        COALESCE(x.D:dependant_spouse::INT,    c.DEPENDANT_SPOUSE),
        COALESCE(x.D:insurance_usd::FLOAT,     c.INSURANCE_USD),
        COALESCE(x.D:visa_usd::FLOAT,          c.VISA_USD),
        COALESCE(x.D:work_permit_usd::FLOAT,   c.WORK_PERMIT_USD),
        COALESCE(x.D:fringe_benefit_usd::FLOAT, c.FRINGE_BENEFIT_USD),
        COALESCE(x.D:change_reason::TEXT, 'Contract change'),
        IFF(COALESCE(x.D:tax_status::TEXT, c.TAX_STATUS) = 'RESIDENT', NULL,
            IFF(IS_NULL_VALUE(x.D:non_resident_from), NULL,
                COALESCE(x.D:non_resident_from::DATE, c.NON_RESIDENT_FROM))),
        IFF(COALESCE(x.D:tax_status::TEXT, c.TAX_STATUS) = 'RESIDENT', NULL,
            IFF(IS_NULL_VALUE(x.D:non_resident_to), NULL,
                COALESCE(x.D:non_resident_to::DATE, c.NON_RESIDENT_TO)))
      INTO :v_position, :v_emp_type, :v_contract, :v_entity, :v_salary, :v_tax, :v_children, :v_spouse,
           :v_insurance, :v_visa, :v_permit, :v_fringe, :v_reason, :v_nr_from, :v_nr_to
    FROM APP.T_D_EMPLOYEE_CONTRACT c, (SELECT PARSE_JSON(:P_CONTRACT) AS D) x
    WHERE c.CONTRACT_ID = :v_cur_id;

    SELECT COUNT(*) INTO :v_entity_ok FROM APP.T_D_ENTITY WHERE ENTITY_CODE = :v_entity AND IS_ACTIVE;
    IF (v_salary < 0 OR v_insurance < 0 OR v_visa < 0 OR v_permit < 0 OR v_fringe < 0 OR v_children < 0
        OR (v_spouse <> 0 AND v_spouse <> 1) OR (v_tax <> 'RESIDENT' AND v_tax <> 'NON_RESIDENT')
        OR v_entity_ok = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Invalid values: amounts must be >= 0, spouse 0 or 1, tax status RESIDENT / NON_RESIDENT, and the chamber must exist.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_old FROM APP.T_D_EMPLOYEE_CONTRACT WHERE CONTRACT_ID = :v_cur_id;

    IF (v_cur_from = v_eff) THEN
        -- Same starting month: correct the version in place
        UPDATE APP.T_D_EMPLOYEE_CONTRACT
        SET POSITION = :v_position, EMPLOYMENT_TYPE = :v_emp_type, CONTRACT_TYPE = :v_contract,
            ENTITY_CODE = :v_entity, MONTHLY_SALARY_USD = :v_salary, TAX_STATUS = :v_tax,
            DEPENDANT_CHILDREN = :v_children, DEPENDANT_SPOUSE = :v_spouse,
            INSURANCE_USD = :v_insurance, VISA_USD = :v_visa, WORK_PERMIT_USD = :v_permit,
            FRINGE_BENEFIT_USD = :v_fringe, CHANGE_REASON = :v_reason,
            NON_RESIDENT_FROM = :v_nr_from, NON_RESIDENT_TO = :v_nr_to,
            UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE CONTRACT_ID = :v_cur_id;
    ELSE
        -- Close the version in force the month before, add the new version
        UPDATE APP.T_D_EMPLOYEE_CONTRACT
        SET VALID_TO_PERIOD_KEY = :v_prev, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
        WHERE CONTRACT_ID = :v_cur_id;

        INSERT INTO APP.T_D_EMPLOYEE_CONTRACT
            (EMPLOYEE_ID, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, POSITION, EMPLOYMENT_TYPE, CONTRACT_TYPE, ENTITY_CODE,
             MONTHLY_SALARY_USD, TAX_STATUS, DEPENDANT_CHILDREN, DEPENDANT_SPOUSE, INSURANCE_USD, VISA_USD,
             WORK_PERMIT_USD, FRINGE_BENEFIT_USD, CHANGE_REASON, NON_RESIDENT_FROM, NON_RESIDENT_TO, INSERT_BY, UPDATE_BY)
        SELECT :P_EMPLOYEE_ID, :v_eff, :v_cur_to, :v_position, :v_emp_type, :v_contract, :v_entity,
               :v_salary, :v_tax, :v_children, :v_spouse, :v_insurance, :v_visa,
               :v_permit, :v_fringe, :v_reason, :v_nr_from, :v_nr_to, :P_USER_EMAIL, :P_USER_EMAIL;
    END IF;

    SELECT TO_JSON(OBJECT_CONSTRUCT_KEEP_NULL(*)) INTO :v_new
    FROM APP.T_D_EMPLOYEE_CONTRACT
    WHERE EMPLOYEE_ID = :P_EMPLOYEE_ID
      AND :v_eff BETWEEN VALID_FROM_PERIOD_KEY AND COALESCE(VALID_TO_PERIOD_KEY, 999912);
    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_EMPLOYEE_CONTRACT', OBJECT_CONSTRUCT('EMPLOYEE_ID', :P_EMPLOYEE_ID, 'EFFECTIVE_PERIOD_KEY', :v_eff), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_open IS NOT NULL AND v_open >= v_eff) THEN
        v_ids := '[' || P_EMPLOYEE_ID || ']';
        CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_actual, :v_open, :v_ids, 'Contract changed');
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_actual, :v_open);
    END IF;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Contract saved from ' || v_eff || '.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_FUND_ALLOCATION(P_USER_EMAIL TEXT, P_SCENARIO_ID INT, P_PERIOD_KEY INT, P_EMPLOYEE_ID INT, P_ALLOCATIONS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves the fund split of one employee'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_type        TEXT;
    v_scen_status TEXT;
    v_status      TEXT;
    v_wd          INT;
    v_allowed     INT;
    v_in_payroll  INT;
    v_rows        INT;
    v_bad         INT;
    v_dupes       INT;
    v_total       FLOAT;
    v_old         TEXT;
    v_new         TEXT;
    v_ids         TEXT;
BEGIN
    SELECT MAX(s.SCENARIO_TYPE), MAX(s.SCENARIO_STATUS), MAX(x.PERIOD_STATUS), MAX(x.WORKING_DAYS)
      INTO :v_type, :v_scen_status, :v_status, :v_wd
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD x ON x.SCENARIO_ID = s.SCENARIO_ID AND x.PERIOD_KEY = :P_PERIOD_KEY
    WHERE s.SCENARIO_ID = :P_SCENARIO_ID;
    IF (v_type IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Scenario ' || P_SCENARIO_ID || ' does not exist.');
    END IF;
    IF (v_status IS NULL) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' does not exist in this scenario.');
    END IF;
    IF (v_type = 'ACTUAL' AND v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL') THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Period ' || P_PERIOD_KEY || ' is ' || v_status || ' and cannot be edited.');
    END IF;
    IF (v_type <> 'ACTUAL' AND ((v_scen_status <> 'DRAFT' AND v_scen_status <> 'REJECTED') OR v_status <> 'DRAFT')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'This scenario is ' || v_scen_status || ' and cannot be edited.');
    END IF;

    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT COUNT(*) INTO :v_in_payroll
    FROM (SELECT EMPLOYEE_ID FROM APP.T_F_PAYROLL_INPUT
          WHERE :v_type = 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID
          UNION
          SELECT EMPLOYEE_ID FROM APP.T_D_SCENARIO_EMPLOYEE
          WHERE :v_type <> 'ACTUAL' AND SCENARIO_ID = :P_SCENARIO_ID AND EMPLOYEE_ID = :P_EMPLOYEE_ID);
    IF (v_in_payroll = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Employee ' || P_EMPLOYEE_ID || ' is not part of this payroll.');
    END IF;

    -- Checks, and the new split (rows with a share > 0) kept in v_new
    SELECT COUNT(*), COUNT(*) - COUNT(DISTINCT t.CODE), COALESCE(SUM(t.SHARE_PCT), 0),
           COUNT_IF(t.CODE IS NULL OR t.SHARE_PCT IS NULL OR t.SHARE_PCT < 0 OR d.FUND_CODE IS NULL),
           TO_JSON(ARRAY_AGG(IFF(t.SHARE_PCT > 0, OBJECT_CONSTRUCT('fund_code', t.CODE, 'share_pct', t.SHARE_PCT), NULL)))
      INTO :v_rows, :v_dupes, :v_total, :v_bad, :v_new
    FROM (SELECT f.VALUE:fund_code::TEXT AS CODE,
                 COALESCE(f.VALUE:share_pct::FLOAT, f.VALUE:days::FLOAT / NULLIF(:v_wd, 0) * 100) AS SHARE_PCT
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_ALLOCATIONS))) f) t
    LEFT JOIN APP.T_D_FUND d ON d.FUND_CODE = t.CODE AND d.IS_ACTIVE;
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs a known, active fund code and a share >= 0, with no duplicates.');
    END IF;
    IF (ABS(v_total - 100) > 0.01) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'The shares total ' || ROUND(v_total, 2) || '%. They must total 100%.');
    END IF;

    BEGIN TRANSACTION;

    SELECT TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('fund_code', FUND_CODE, 'share_pct', SHARE_PCT))) INTO :v_old
    FROM APP.T_F_FUND_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    DELETE FROM APP.T_F_FUND_ALLOCATION WHERE SCENARIO_ID = :P_SCENARIO_ID AND PERIOD_KEY = :P_PERIOD_KEY AND EMPLOYEE_ID = :P_EMPLOYEE_ID;

    INSERT INTO APP.T_F_FUND_ALLOCATION (SCENARIO_ID, PERIOD_KEY, EMPLOYEE_ID, FUND_CODE, SHARE_PCT, INSERT_BY, UPDATE_BY)
    SELECT :P_SCENARIO_ID, :P_PERIOD_KEY, :P_EMPLOYEE_ID, VALUE:fund_code::TEXT, VALUE:share_pct::FLOAT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)));

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_F_FUND_ALLOCATION', OBJECT_CONSTRUCT('SCENARIO_ID', :P_SCENARIO_ID, 'PERIOD_KEY', :P_PERIOD_KEY, 'EMPLOYEE_ID', :P_EMPLOYEE_ID), 'UPDATE', PARSE_JSON(:v_old), PARSE_JSON(:v_new), :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL;

    IF (v_type = 'ACTUAL') THEN
        v_ids := '[' || P_EMPLOYEE_ID || ']';
        CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY, :v_ids, 'Fund split changed');
    END IF;
    CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :P_SCENARIO_ID, :P_PERIOD_KEY);

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'Fund split saved.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_STATUTORY_PARAMETER(P_USER_EMAIL TEXT, P_PERIOD_KEY INT, P_PARAMS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Changes statutory parameters from the open payroll month onward'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed  INT;
    v_status   TEXT;
    v_prev_key INT;
    v_rows     INT;
    v_bad      INT;
    v_dupes    INT;
    v_changed  INT;
    v_recalc   INT;
    v_sid      INT;
    v_pk       INT;
    v_type     TEXT;
    v_params      TEXT;   -- JSON array: changed parameters with the row in force
    v_recalc_rows TEXT;   -- JSON array: scenario months to recalculate
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    SELECT MAX(x.PERIOD_STATUS) INTO :v_status
    FROM APP.T_F_SCENARIO_PERIOD x
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL'
    WHERE x.PERIOD_KEY = :P_PERIOD_KEY;
    IF (v_status IS NULL OR (v_status <> 'OPEN' AND v_status <> 'IN_APPROVAL')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Month ' || COALESCE(P_PERIOD_KEY::TEXT, '?') || ' is not the open payroll month; parameters can only change from the open month.');
    END IF;

    v_prev_key := TO_NUMBER(TO_CHAR(DATEADD(MONTH, -1, TO_DATE(P_PERIOD_KEY::TEXT, 'YYYYMM')), 'YYYYMM'));

    -- Each sent value with the row in force in P_PERIOD_KEY, checked; the changed ones kept in v_params
    SELECT COUNT(*),
           COUNT_IF(NOT FOUND OR NEW_VALUE IS NULL OR NEW_VALUE < 0 OR (UNIT = 'RATE' AND NEW_VALUE > 1)),
           COUNT(*) - COUNT(DISTINCT PARAM_CODE),
           COUNT_IF(FOUND AND ABS(NEW_VALUE - OLD_VALUE) > 1e-9),
           TO_JSON(ARRAY_AGG(IFF(FOUND AND ABS(NEW_VALUE - OLD_VALUE) > 1e-9,
               OBJECT_CONSTRUCT_KEEP_NULL('PARAM_CODE', PARAM_CODE, 'NEW_VALUE', NEW_VALUE, 'OLD_FROM', OLD_FROM,
                   'OLD_TO', OLD_TO, 'OLD_VALUE', OLD_VALUE, 'UNIT', UNIT, 'DESCRIPTION', DESCRIPTION,
                   'LEGAL_REFERENCE', LEGAL_REFERENCE), NULL)))
      INTO :v_rows, :v_bad, :v_dupes, :v_changed, :v_params
    FROM (SELECT f.VALUE:param_code::TEXT    AS PARAM_CODE,
                 f.VALUE:param_value::FLOAT  AS NEW_VALUE,
                 sp.PARAM_CODE IS NOT NULL   AS FOUND,
                 sp.VALID_FROM_PERIOD_KEY    AS OLD_FROM,
                 sp.VALID_TO_PERIOD_KEY      AS OLD_TO,
                 sp.PARAM_VALUE              AS OLD_VALUE,
                 sp.UNIT, sp.DESCRIPTION, sp.LEGAL_REFERENCE
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_PARAMS))) f
          LEFT JOIN APP.T_P_STATUTORY_PARAMETER sp
                 ON sp.PARAM_CODE = f.VALUE:param_code::TEXT
                AND :P_PERIOD_KEY BETWEEN sp.VALID_FROM_PERIOD_KEY AND COALESCE(sp.VALID_TO_PERIOD_KEY, 999912));
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each parameter needs a known code and a value of 0 or more (rates at most 100%), with no duplicates.');
    END IF;
    IF (v_changed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    -- Scenario periods from P_PERIOD_KEY on that take the new values
    SELECT COUNT(*),
           TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('SCENARIO_ID', x.SCENARIO_ID, 'PERIOD_KEY', x.PERIOD_KEY,
                                              'SCENARIO_TYPE', s.SCENARIO_TYPE)))
      INTO :v_recalc, :v_recalc_rows
    FROM APP.T_F_SCENARIO_PERIOD x
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID
    WHERE x.PERIOD_KEY >= :P_PERIOD_KEY
      AND (   (s.SCENARIO_TYPE = 'ACTUAL' AND x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'))
           OR (s.SCENARIO_TYPE = 'FORECAST' AND s.SCENARIO_STATUS = 'DRAFT' AND x.PERIOD_STATUS = 'DRAFT')
           OR (s.SCENARIO_TYPE = 'BUDGET' AND s.SCENARIO_STATUS IN ('DRAFT', 'REJECTED') AND x.PERIOD_STATUS = 'DRAFT'));

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_P_STATUTORY_PARAMETER',
           OBJECT_CONSTRUCT('PARAM_CODE', VALUE:PARAM_CODE::TEXT, 'VALID_FROM_PERIOD_KEY', :P_PERIOD_KEY),
           IFF(VALUE:OLD_FROM::INT = :P_PERIOD_KEY, 'UPDATE', 'INSERT'),
           OBJECT_CONSTRUCT('PARAM_VALUE', VALUE:OLD_VALUE::FLOAT, 'VALID_FROM_PERIOD_KEY', VALUE:OLD_FROM::INT),
           OBJECT_CONSTRUCT('PARAM_VALUE', VALUE:NEW_VALUE::FLOAT, 'VALID_FROM_PERIOD_KEY', :P_PERIOD_KEY),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)));

    -- Started this month: change the value in place
    UPDATE APP.T_P_STATUTORY_PARAMETER sp
    SET PARAM_VALUE = t.VALUE:NEW_VALUE::FLOAT, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)))) t
    WHERE sp.PARAM_CODE = t.VALUE:PARAM_CODE::TEXT AND sp.VALID_FROM_PERIOD_KEY = :P_PERIOD_KEY
      AND t.VALUE:OLD_FROM::INT = :P_PERIOD_KEY;

    -- Started earlier: end it last month, new row from this month
    UPDATE APP.T_P_STATUTORY_PARAMETER sp
    SET VALID_TO_PERIOD_KEY = :v_prev_key, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)))) t
    WHERE sp.PARAM_CODE = t.VALUE:PARAM_CODE::TEXT AND sp.VALID_FROM_PERIOD_KEY = t.VALUE:OLD_FROM::INT
      AND t.VALUE:OLD_FROM::INT < :P_PERIOD_KEY;

    INSERT INTO APP.T_P_STATUTORY_PARAMETER
        (PARAM_CODE, VALID_FROM_PERIOD_KEY, VALID_TO_PERIOD_KEY, PARAM_VALUE, UNIT, DESCRIPTION, LEGAL_REFERENCE, INSERT_BY, UPDATE_BY)
    SELECT VALUE:PARAM_CODE::TEXT, :P_PERIOD_KEY, VALUE:OLD_TO::INT, VALUE:NEW_VALUE::FLOAT, VALUE:UNIT::TEXT,
           VALUE:DESCRIPTION::TEXT, VALUE:LEGAL_REFERENCE::TEXT, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_params)))
    WHERE VALUE:OLD_FROM::INT < :P_PERIOD_KEY;

    LET rs RESULTSET := (SELECT VALUE:SCENARIO_ID::INT AS SCENARIO_ID, VALUE:PERIOD_KEY::INT AS PERIOD_KEY,
                                VALUE:SCENARIO_TYPE::TEXT AS SCENARIO_TYPE
                         FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_recalc_rows)))
                         ORDER BY SCENARIO_ID, PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_sid  := rec.SCENARIO_ID;
        v_pk   := rec.PERIOD_KEY;
        v_type := rec.SCENARIO_TYPE;
        IF (v_type = 'ACTUAL') THEN
            CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_sid, :v_pk, NULL, 'Statutory parameters changed');
        END IF;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_sid, :v_pk);
    END FOR;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' parameter(s) saved from ' || P_PERIOD_KEY || '; ' || v_recalc || ' month(s) recalculated.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;

CREATE OR REPLACE PROCEDURE APP.SP_SAVE_WORKING_DAYS(P_USER_EMAIL TEXT, P_CALENDAR TEXT, P_DAYS TEXT)
COPY GRANTS
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Saves working days of the actual or budget calendar'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_allowed   INT;
    v_rows      INT;
    v_bad       INT;
    v_dupes     INT;
    v_finalized INT;
    v_changed   INT;
    v_sid       INT;
    v_pk        INT;
    v_type      TEXT;
    v_new       TEXT;   -- JSON array: changed months (PERIOD_KEY, WORKING_DAYS, OLD_WORKING_DAYS)
    v_recalc    TEXT;   -- JSON array: scenario months that take the new value
BEGIN
    SELECT COUNT(*) INTO :v_allowed
    FROM APP.T_D_APP_USER u
    WHERE u.USER_EMAIL = :P_USER_EMAIL AND u.IS_ACTIVE;
    IF (v_allowed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'You are not an active app user. Ask a developer to add you in Snowflake.');
    END IF;

    IF (P_CALENDAR IS NULL OR (P_CALENDAR <> 'ACTUAL' AND P_CALENDAR <> 'BUDGET')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'P_CALENDAR must be ACTUAL or BUDGET.');
    END IF;

    -- Checks on every row, and the changed months kept for the writes
    SELECT COUNT(*), COUNT_IF(NOT IN_CALENDAR OR WORKING_DAYS IS NULL OR WORKING_DAYS < 0 OR WORKING_DAYS > DAYS_IN_MONTH),
           COUNT(*) - COUNT(DISTINCT PERIOD_KEY),
           COUNT_IF(NOT EQUAL_NULL(WORKING_DAYS, OLD_WORKING_DAYS)),
           TO_JSON(ARRAY_AGG(IFF(NOT EQUAL_NULL(WORKING_DAYS, OLD_WORKING_DAYS),
               OBJECT_CONSTRUCT_KEEP_NULL('PERIOD_KEY', PERIOD_KEY, 'WORKING_DAYS', WORKING_DAYS,
                                          'OLD_WORKING_DAYS', OLD_WORKING_DAYS), NULL)))
      INTO :v_rows, :v_bad, :v_dupes, :v_changed, :v_new
    FROM (SELECT f.VALUE:period_key::INT AS PERIOD_KEY, f.VALUE:working_days::INT AS WORKING_DAYS,
                 p.PERIOD_KEY IS NOT NULL AS IN_CALENDAR, DAY(p.PERIOD_END_DATE) AS DAYS_IN_MONTH,
                 IFF(:P_CALENDAR = 'ACTUAL', p.WORKING_DAYS, p.BUDGET_WORKING_DAYS) AS OLD_WORKING_DAYS
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:P_DAYS))) f
          LEFT JOIN APP.T_D_PERIOD p ON p.PERIOD_KEY = f.VALUE:period_key::INT);
    IF (v_rows = 0 OR v_bad > 0 OR v_dupes > 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', 'Each row needs a month in the calendar and 0 to (days in month) working days, with no duplicates.');
    END IF;
    IF (v_changed = 0) THEN
        RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', 'No changes to save.');
    END IF;

    IF (P_CALENDAR = 'ACTUAL') THEN
        SELECT COUNT(*) INTO :v_finalized
        FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new))) t
        JOIN APP.T_F_SCENARIO_PERIOD x ON x.PERIOD_KEY = t.VALUE:PERIOD_KEY::INT AND x.PERIOD_STATUS = 'FINALIZED'
        JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID AND s.SCENARIO_TYPE = 'ACTUAL';
        IF (v_finalized > 0) THEN
            RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', v_finalized || ' of the changed months are finalized and cannot change.');
        END IF;
    END IF;

    -- Scenario periods that take the new value (open actual month, draft forecasts / budgets)
    SELECT TO_JSON(ARRAY_AGG(OBJECT_CONSTRUCT('SCENARIO_ID', x.SCENARIO_ID, 'PERIOD_KEY', x.PERIOD_KEY,
                                              'SCENARIO_TYPE', s.SCENARIO_TYPE, 'WORKING_DAYS', t.VALUE:WORKING_DAYS::INT)))
      INTO :v_recalc
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new))) t
    JOIN APP.T_F_SCENARIO_PERIOD x ON x.PERIOD_KEY = t.VALUE:PERIOD_KEY::INT
    JOIN APP.T_D_SCENARIO s ON s.SCENARIO_ID = x.SCENARIO_ID
    WHERE t.VALUE:WORKING_DAYS::INT > 0
      AND (   (:P_CALENDAR = 'ACTUAL' AND s.SCENARIO_TYPE = 'ACTUAL' AND x.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'))
           OR (:P_CALENDAR = 'ACTUAL' AND s.SCENARIO_TYPE = 'FORECAST' AND s.SCENARIO_STATUS = 'DRAFT' AND x.PERIOD_STATUS = 'DRAFT')
           OR (:P_CALENDAR = 'BUDGET' AND s.SCENARIO_TYPE = 'BUDGET' AND s.SCENARIO_STATUS IN ('DRAFT', 'REJECTED') AND x.PERIOD_STATUS = 'DRAFT'));

    BEGIN TRANSACTION;

    INSERT INTO APP.T_F_CHANGE_LOG (TABLE_NAME, RECORD_KEY, CHANGE_TYPE, OLD_VALUES, NEW_VALUES, CHANGED_BY, INSERT_BY, UPDATE_BY)
    SELECT 'APP.T_D_PERIOD', OBJECT_CONSTRUCT('PERIOD_KEY', t.VALUE:PERIOD_KEY::INT, 'CALENDAR', :P_CALENDAR), 'UPDATE',
           OBJECT_CONSTRUCT_KEEP_NULL('WORKING_DAYS', t.VALUE:OLD_WORKING_DAYS::INT),
           OBJECT_CONSTRUCT('WORKING_DAYS', t.VALUE:WORKING_DAYS::INT),
           :P_USER_EMAIL, :P_USER_EMAIL, :P_USER_EMAIL
    FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new))) t;

    UPDATE APP.T_D_PERIOD p
    SET WORKING_DAYS        = IFF(:P_CALENDAR = 'ACTUAL', t.WD, p.WORKING_DAYS),
        BUDGET_WORKING_DAYS = IFF(:P_CALENDAR = 'BUDGET', t.WD, p.BUDGET_WORKING_DAYS),
        UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE:PERIOD_KEY::INT AS PK, VALUE:WORKING_DAYS::INT AS WD
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_new)))) t
    WHERE p.PERIOD_KEY = t.PK;

    UPDATE APP.T_F_SCENARIO_PERIOD x
    SET WORKING_DAYS = r.WD, UPDATE_DATE = CURRENT_TIMESTAMP, UPDATE_BY = :P_USER_EMAIL
    FROM (SELECT VALUE:SCENARIO_ID::INT AS SID, VALUE:PERIOD_KEY::INT AS PK, VALUE:WORKING_DAYS::INT AS WD
          FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_recalc)))) r
    WHERE x.SCENARIO_ID = r.SID AND x.PERIOD_KEY = r.PK;

    LET rs RESULTSET := (SELECT VALUE:SCENARIO_ID::INT AS SCENARIO_ID, VALUE:PERIOD_KEY::INT AS PERIOD_KEY,
                                VALUE:SCENARIO_TYPE::TEXT AS SCENARIO_TYPE
                         FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:v_recalc)))
                         ORDER BY SCENARIO_ID, PERIOD_KEY);
    LET cur CURSOR FOR rs;
    FOR rec IN cur DO
        v_sid  := rec.SCENARIO_ID;
        v_pk   := rec.PERIOD_KEY;
        v_type := rec.SCENARIO_TYPE;
        IF (v_type = 'ACTUAL') THEN
            CALL APP.SP_RESET_APPROVALS(:P_USER_EMAIL, :v_sid, :v_pk, NULL, 'Working days changed');
        END IF;
        CALL APP.SP_CALC_PERIOD(:P_USER_EMAIL, :v_sid, :v_pk);
    END FOR;

    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'OK', 'message', v_changed || ' month(s) saved in the ' || LOWER(P_CALENDAR) || ' calendar.');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RETURN OBJECT_CONSTRUCT('status', 'ERROR', 'message', SQLERRM, 'code', SQLCODE);
END;
$$;
