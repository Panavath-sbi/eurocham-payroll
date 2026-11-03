CREATE OR REPLACE VIEW RPT.V_D_PBI_EMPLOYEE 
(
    "Employee_ID"   COMMENT 'Resource ID shown to users, e.g. HR-FRA-001',
    "Employee_Name" COMMENT 'First name and last name, e.g. Martin BRISSON'
)
COMMENT = 'Power BI: DimEmployee (one row per employee)'
AS
SELECT
    e.RESOURCE_CODE                                                      AS "Employee_ID",
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')) AS "Employee_Name"
FROM APP.T_D_EMPLOYEE e
WHERE NOT e.IS_PLANNED;
