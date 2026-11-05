CREATE STAGE IF NOT EXISTS APP.PAYSLIP_TEMPLATE
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Fillable payslip form (payslip_fillable.pdf, uploaded by hand) read by APP.FN_PAYSLIP_PDF';
