-- 2026-10-19  Baseline for DLSync: the table as it stands after V1.0.0 - V1.8.0 (created in CORE by V1.0.1, moved to APP by V1.5.0, which added FX_RATE_NBC and FX_RATE_NSSF).
-- CREATE TABLE IF NOT EXISTS: dbt runs this on every build; an existing table keeps its rows.
CREATE TABLE IF NOT EXISTS T_D_PERIOD (
    PERIOD_KEY          INT       NOT NULL COMMENT 'Period identifier in YYYYMM form, e.g. 202609',
    PERIOD_START_DATE   DATE      NOT NULL COMMENT 'First day of the month',
    PERIOD_END_DATE     DATE      NOT NULL COMMENT 'Last day of the month',
    YEAR                INT       NOT NULL COMMENT 'Calendar year',
    MONTH_NUMBER        INT       NOT NULL COMMENT 'Month number 1-12',
    MONTH_NAME          TEXT      NOT NULL COMMENT 'Full month name, e.g. September',
    PERIOD_LABEL        TEXT      NOT NULL COMMENT 'Display label, e.g. Sep 2026',
    QUARTER             INT       NOT NULL COMMENT 'Calendar quarter 1-4',
    HALF_YEAR           INT       NOT NULL COMMENT '1 = Jan-Jun, 2 = Jul-Dec (seniority averaging window)',
    IS_SENIORITY_MONTH  BOOLEAN   NOT NULL COMMENT 'TRUE for June and December, when seniority indemnity is paid',
    FISCAL_YEAR         INT       NOT NULL COMMENT 'Fiscal year (currently equal to calendar year)',
    WEEKDAY_COUNT       INT       NOT NULL COMMENT 'Number of Monday-Friday days in the month (reference only)',
    WORKING_DAYS        INT                COMMENT 'Official working days for actual payroll; NULL or 0 = not yet set',
    BUDGET_WORKING_DAYS INT                COMMENT 'Working days used by budget scenarios; NULL or 0 = not yet set',
    INSERT_DATE         TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Row creation timestamp',
    UPDATE_DATE         TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    INSERT_BY           TEXT      DEFAULT CURRENT_USER      COMMENT 'User who created the row',
    UPDATE_BY           TEXT      DEFAULT CURRENT_USER      COMMENT 'User who last updated the row',
    FX_RATE_NBC          FLOAT              COMMENT 'Published NBC USD-KHR rate (gross pay and tax conversion); NULL = not yet published',
    FX_RATE_NSSF         FLOAT              COMMENT 'Published NSSF USD-KHR rate (NSSF base conversion); NULL = not yet published',
    CONSTRAINT PK_T_D_PERIOD PRIMARY KEY (PERIOD_KEY)
) COMMENT = 'Calendar month dimension (one row per month): calendar attributes, working days (actual and budget) and the published NBC / NSSF exchange rates. The values actually applied to a scenario month are copied into T_F_SCENARIO_PERIOD.';

-- 2026-10-19  Reference data (from V1.1.0): 192 months, Jan 2020 - Dec 2035. Working days and FX rates are set in the app.
-- Reference rows: inserted once, only while the table is empty.
EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM T_D_PERIOD;
    IF (n = 0) THEN
        INSERT INTO T_D_PERIOD (
            PERIOD_KEY, PERIOD_START_DATE, PERIOD_END_DATE, YEAR, MONTH_NUMBER, MONTH_NAME,
            PERIOD_LABEL, QUARTER, HALF_YEAR, IS_SENIORITY_MONTH, FISCAL_YEAR, WEEKDAY_COUNT)
        WITH months AS (
            SELECT DATEADD(MONTH, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2020-01-01'::DATE) AS M
            FROM TABLE(GENERATOR(ROWCOUNT => 192))
        ),
        days AS (
            SELECT DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2020-01-01'::DATE) AS D
            FROM TABLE(GENERATOR(ROWCOUNT => 5845))          -- 2020-01-01 to 2035-12-31
        ),
        weekdays AS (
            SELECT DATE_TRUNC('MONTH', D) AS M, COUNT_IF(DAYOFWEEKISO(D) <= 5) AS WEEKDAY_COUNT
            FROM days
            GROUP BY 1
        )
        SELECT
            YEAR(m.M) * 100 + MONTH(m.M),
            m.M,
            LAST_DAY(m.M),
            YEAR(m.M),
            MONTH(m.M),
            TO_CHAR(m.M, 'MMMM'),
            TO_CHAR(m.M, 'Mon YYYY'),
            QUARTER(m.M),
            IFF(MONTH(m.M) <= 6, 1, 2),
            MONTH(m.M) IN (6, 12),
            YEAR(m.M),
            w.WEEKDAY_COUNT
        FROM months m
        JOIN weekdays w ON w.M = m.M;
    END IF;
END;
$$;
