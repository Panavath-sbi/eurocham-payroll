EXECUTE IMMEDIATE $$
DECLARE
    n INTEGER;
BEGIN
    SELECT COUNT(*) INTO :n FROM APP.T_D_DEPARTMENT;
    IF (n = 0) THEN
        INSERT INTO APP.T_D_DEPARTMENT (DEPARTMENT_CODE, DEPARTMENT_NAME, DISPLAY_ORDER) VALUES
            ('ADMIN',         'Admin',         1),
            ('ADVOCACY',      'Advocacy',      2),
            ('COMMUNICATION', 'Communication', 3),
            ('EVENTS',        'Events',        4),
            ('EXECUTIVE',     'Executive',     5),
            ('MEMBERSHIPS',   'Memberships',   6),
            ('SERVICES',      'Services',      7);
    END IF;
END;
$$;
