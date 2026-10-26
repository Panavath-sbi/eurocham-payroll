-- depends_on: T_F_SCENARIO_PERIOD, T_P_STATUTORY_PARAMETER, T_P_TAX_BRACKET, T_F_PAYROLL_LINE, T_D_SCENARIO, T_D_PERIOD, T_D_EMPLOYEE_CONTRACT, T_D_SCENARIO_EMPLOYEE, T_F_PAYROLL_INPUT
USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   SP_CALC_PERIOD
   Internal: calculates the pay lines of one scenario period.
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-09-29  Fix: COMMENT moved before EXECUTE AS (Snowflake clause order).
   2026-10-02  V1.5.0: payroll adjustments removed (no ADJUSTMENT line); cost allocation is
               no longer stored (RPT.V_F_COST_ALLOCATION calculates it); CORE -> APP.
   2026-10-19  Own file for DLSync: no USE DATABASE, names qualified with ${DB}, COPY GRANTS
               keeps the app's USAGE grant when the procedure is replaced.
   2026-10-26  Fix: no seniority for FDC (fixed-duration) contracts; empty contract type
               counts as UDC.

   CONVENTIONS
   -----------
   * Every public procedure takes P_USER_EMAIL (the Power Apps user, passed by Power
     Automate), checks the user role, writes INSERT_BY / UPDATE_BY and T_F_CHANGE_LOG.
   * Every public procedure returns a VARIANT: {"status": "OK" | "ERROR", "message": "..."}.
     Power Automate returns it to the app as is.
   * Validations run before any write. Writes run in one transaction; any error rolls
     the whole call back.
   * Currency rule: earnings are calculated in USD and converted to KHR at the NBC rate
     (from the unrounded USD). NSSF and salary tax are calculated in KHR and converted
     back to USD, rounded to the cent. Net pay USD = gross USD - deductions USD.

   CALCULATION RULES (from the current DEV system - verify)
   ---------------------------------------------------------
   Daily rate          = salary / working days of the scenario period
   Unpaid leave        = daily rate x absence days (negative earning)
   Overtime            = daily rate x overtime days x OVERTIME_MULTIPLIER
   Outstanding leave   = daily rate x outstanding days
   Seniority (Jun/Dec) = average (salary + bonus) over the half-year / working days
                         x SENIORITY_DAYS_PER_PAYMENT; UDC contracts only (none for FDC)
   NSSF base (KHR)     = (salary + seniority) x NSSF rate, between floor and cap
   Taxable base (KHR)  = taxable earnings - seniority exemption - employee NSSF
   Resident tax        = bracket rate x (taxable base - dependant relief) - deduction
   Non-resident tax    = flat rate x taxable base, no dependant relief

   KNOWN LIMITS (to be decided)
   ----------------------------
   * Seniority eligibility (minimum service) is not checked.
   * Fringe benefit tax is not calculated; fringe benefits are an employer cost only.
   * Allocated cost (RPT.V_F_COST_ALLOCATION) is rounded per fund x department row, so
     splits can differ from the employee total by a cent.
   * Budget / forecast employees with no input row for a month are included by default.
   ===================================================================================== */
/* =====================================================================================
   SP_CALC_PERIOD (internal)
   Rewrites T_F_PAYROLL_LINE for one scenario period.
   No transaction and no role check: only called by the procedures below, inside
   their own transaction. Raises an error instead of returning one.
   ===================================================================================== */
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
