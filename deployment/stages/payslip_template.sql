USE ROLE "{{ role_owner }}";
USE DATABASE {{ database }};

/* =====================================================================================
   PAYSLIP_TEMPLATE - internal stage holding the fillable payslip form
   =====================================================================================

   HISTORY
   -------
   2026-10-27  Initial version.

   NOTES
   -----
   * Holds one file, payslip_fillable.pdf: the Word payslip template exported to PDF,
     with one form field per value (field names = the keys APP.FN_PAYSLIP_PDF fills).
     A template only: no employee data is ever written here.
   * The file is uploaded by hand, never by the pipeline (Snowsight: Data > Databases >
     <database> > APP > Stages > PAYSLIP_TEMPLATE > + Files, or COPY FILES from the uat
     stage). A design change = a new file under the same name, tested in uat first.
   * SNOWFLAKE_SSE (server-side encryption) so code can read the file. The encryption
     of a stage cannot be changed after creation.
   * Read by APP.FN_PAYSLIP_PDF with its owner's rights; callers need no rights here.
   ===================================================================================== */
CREATE STAGE IF NOT EXISTS APP.PAYSLIP_TEMPLATE
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Fillable payslip form (payslip_fillable.pdf, uploaded by hand) read by APP.FN_PAYSLIP_PDF';
