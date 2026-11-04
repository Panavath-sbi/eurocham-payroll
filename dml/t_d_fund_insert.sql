EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM APP.T_D_FUND;
    IF (n = 0) THEN
        INSERT INTO APP.T_D_FUND (FUND_CODE, FUND_NAME) VALUES
            ('ECCC',    'ECCC'),
            ('CCIFC',   'CCIFC'),
            ('EU_GATE', 'EU Gate');
    END IF;
END;
$$;
