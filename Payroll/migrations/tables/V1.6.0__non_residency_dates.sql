/* =====================================================================================
   V1.6.0 - NON-RESIDENCY DATES ON THE CONTRACT
   =====================================================================================

   HISTORY
   -------
   2026-10-05  Initial version. Two dates on APP.T_D_EMPLOYEE_CONTRACT for non-resident
               employees. They do not change the tax calculation (only TAX_STATUS does);
               they let SP_OPEN_PAYROLL_PERIOD switch the employee to RESIDENT
               automatically once the non-residency has ended (actual payroll only).
   Versioned file: never edit after deployment.
   ===================================================================================== */

ALTER TABLE APP.T_D_EMPLOYEE_CONTRACT ADD COLUMN NON_RESIDENT_FROM DATE
    COMMENT 'Non-residents only: first day of the non-residency (information)';
ALTER TABLE APP.T_D_EMPLOYEE_CONTRACT ADD COLUMN NON_RESIDENT_TO DATE
    COMMENT 'Non-residents only: last day of the non-residency. When a payroll month opens after this date, a new contract version makes the employee RESIDENT from that month.';
