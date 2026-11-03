EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM APP.T_D_PERIOD;
    IF (n = 0) THEN
        INSERT INTO APP.T_D_PERIOD (
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
