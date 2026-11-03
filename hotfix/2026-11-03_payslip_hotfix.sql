/* =====================================================================================
   HOTFIX 2026-11-03 (payslip objects + V_D_EMPLOYEE) - EuroCham Payroll (EUROCHAM_PAYROLL_DB)
   =====================================================================================
   Run once in a Snowsight worksheet. Set the role (owner of APP / RPT) and the database
   EUROCHAM_PAYROLL_DB in the worksheet first; this script contains no USE statements.
   Safe to run again: CREATE ... IF NOT EXISTS / CREATE OR REPLACE ... COPY GRANTS.
   Source: branch release/v1.0.0. No grants: they are managed by the database owner.
   The 10 procedure fixes are in 20261103_hotfix_procedures_prod.sql (run either one first).

   CONTENTS (in run order)
    1. NEW    stage     APP.PAYSLIP_TEMPLATE
    2. NEW    function  APP.FN_PAYSLIP_PDF
    3. NEW    view      RPT.V_F_PAYSLIP_DOC
    4. FIX    view      RPT.V_D_EMPLOYEE (employee register query)

   AFTER RUNNING
   -------------
   * Upload payslip_fillable.pdf to stage APP.PAYSLIP_TEMPLATE (Snowsight: Data > Databases >
     EUROCHAM_PAYROLL_DB > APP > Stages > PAYSLIP_TEMPLATE > + Files). FN_PAYSLIP_PDF fails until then.
   * Grants for the new objects, if the existing grants do not cover them: USAGE on function
     APP.FN_PAYSLIP_PDF(OBJECT) for DB_WRITER (the payslip flow), SELECT on view
     RPT.V_F_PAYSLIP_DOC for the roles that read it. Replaced objects keep their grants (COPY GRANTS).
   ===================================================================================== */


-- =====================================================================================
--  1. NEW    stage     APP.PAYSLIP_TEMPLATE   (from stages/payslip_template.sql)
-- =====================================================================================
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


-- =====================================================================================
--  2. NEW    function  APP.FN_PAYSLIP_PDF   (from functions/fn_payslip_pdf.sql)
-- =====================================================================================
-- depends_on: PAYSLIP_TEMPLATE

/* =====================================================================================
   FN_PAYSLIP_PDF - one employee's payslip as a PDF (base64)
   =====================================================================================

   HISTORY
   -------
   2026-10-27  Initial version: fills the fillable form on APP.PAYSLIP_TEMPLATE and
               flattens it (replaces the paginated report export in the payslip flow).

   CALLED FROM
   -----------
   The payslip flow (Power Automate), once per employee:
       SELECT APP.FN_PAYSLIP_PDF(OBJECT_CONSTRUCT_KEEP_NULL('Employee_ID', ..., ...))
   The flow turns the result into the PDF attachment with base64ToBinary(...).

   RULES
   -----
   * Input: one OBJECT; keys = the form's field names (Employee_ID, Period, Gross_USD, ...,
     see FORMAT below), values = raw numbers or text. A missing or NULL value leaves its
     box empty. Formatting ($1,250.00 / 80.00% / 5,125,000) is done here.
   * Fields printed twice (Tax_USD_2, Gross_USD_2, ...) are filled from their original.
   * A value too wide for its box is printed smaller (down to 6.5 pt); still too wide,
     it is split onto two lines.
   * The result is flattened: no editable field is left in the PDF.
   * Nothing is stored: the PDF only exists in the returned value.
   * The form is read from the stage when called (once per query), with the owner's
     rights; a replaced form is used from the next query on. Calls fail until
     payslip_fillable.pdf has been uploaded to the stage.
   * The first call after the warehouse resumes loads the Python packages (~50 s);
     later calls take a few seconds. The flow warms it up before its loop.
   * Grants are managed by the database owner (the flow's role DB_WRITER needs USAGE).
   ===================================================================================== */
CREATE OR REPLACE FUNCTION APP.FN_PAYSLIP_PDF(P_DATA OBJECT)
  COPY GRANTS
  RETURNS TEXT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python', 'pypdf==6.8.0')
  HANDLER = 'run'
  COMMENT = 'Payslip PDF as base64: fills the fillable form on APP.PAYSLIP_TEMPLATE with one employee-month (keys = form field names) and flattens it'
AS
$$

import base64, io
from pypdf import PdfReader, PdfWriter
from snowflake.snowpark.files import SnowflakeFile
from pypdf.generic import NameObject, NumberObject
from pypdf._codecs.core_font_metrics import CORE_FONT_METRICS   # pinned pypdf==6.8.0

def usd(x):  return "${:,.2f}".format(x)
def num0(x): return "{:,.0f}".format(x)
def num2(x): return "{:,.2f}".format(x)
def pct0(x): return "{:.0%}".format(x)
def pct2(x): return "{:.2%}".format(x)
def text(x): return str(x)

# How each input value is printed. Keys are the PDF form's field names.
FORMAT = {
    "Employee_ID": text, "Period": text, "Employee_Name": text, "Employee_Position": text,
    "Working_Days": text, "Unpaid_Leave": num2, "Seniority_Pay": usd, "Bonus": usd,
    "Gross_USD": usd, "Total_Benefit": usd, "Taxable_USD": usd, "Tax_USD": usd,
    "NSSF_Deductions": usd, "Net_Pay_USD": usd,
    "ECCC_Pct": pct2, "CCIFC_Pct": pct2, "EU_Gate_Pct": pct2,
    "ECCC_Amount": usd, "CCIFC_Amount": usd, "EU_Gate_Amount": usd,
    "FX_Rate": num0, "Gross_KHR": num0, "Dep_Count": num0, "Dependents_KHR": num0,
    "Tax_KHR": num0, "Taxable_KHR": num0, "Tax_Rate": pct0,
}
# Fields printed in more than one place: the copy takes the value of the original.
COPIES = {"Gross_USD_2": "Gross_USD", "Tax_USD_2": "Tax_USD", "Tax_USD_3": "Tax_USD",
          "ECCC_Total": "ECCC_Amount", "CCIFC_Total": "CCIFC_Amount", "EU_Gate_Total": "EU_Gate_Amount"}

FORM_PATH = "@EUROCHAM_PAYROLL_DB.APP.PAYSLIP_TEMPLATE/payslip_fillable.pdf"
_form = None

def form():
    """The fillable form, read from the stage once per query (a replaced file is used from the next query on)."""
    global _form
    if _form is None:
        with SnowflakeFile.open(FORM_PATH, "rb", require_scoped_url=False) as f:
            _form = f.read()
    return _form

FONT_SIZE, MIN_FONT_SIZE, PADDING = 10.0, 6.5, 4.0
WIDTHS = {"/Helv": CORE_FONT_METRICS["Helvetica"].character_widths,
          "/HeBo": CORE_FONT_METRICS["Helvetica-Bold"].character_widths}
MULTILINE = 4096                                          # field flag: text may wrap

def text_width(text, font, size):
    widths = WIDTHS[font]
    return sum(widths.get(c, 556) for c in text) * size / 1000

def fit(values, page):
    """A value wider than its box is printed smaller (down to MIN_FONT_SIZE);
    still too wide, it is split onto two lines and sized to fit the box."""
    out = {}
    for ref in page["/Annots"]:
        annot = ref.get_object()
        name = annot.get("/T")
        value = values.get(name, "")
        if not value:
            out[name] = value
            continue
        font = "/HeBo" if "/HeBo" in annot["/DA"] else "/Helv"
        room = float(annot["/Rect"][2]) - float(annot["/Rect"][0]) - PADDING
        width = text_width(value, font, FONT_SIZE)
        if width <= room:
            out[name] = value
        elif FONT_SIZE * room / width >= MIN_FONT_SIZE:
            out[name] = (value, font, int(FONT_SIZE * room / width * 10) / 10)
        else:                                             # two lines, split at the best word break
            height = float(annot["/Rect"][3]) - float(annot["/Rect"][1])
            words = value.split()
            splits = [(" ".join(words[:i]), " ".join(words[i:])) for i in range(1, len(words))] or [(value, "")]
            first, second = min(splits, key=lambda s: max(text_width(s[0], font, 1), text_width(s[1], font, 1)))
            longest = max(text_width(first, font, 1), text_width(second, font, 1))
            size = int(min(room / longest, height / 2.3) * 10) / 10
            annot[NameObject("/Ff")] = NumberObject(MULTILINE)
            out[name] = (first + "\n" + second, font, size)
    return out

def run(p_data):
    values = {k: ("" if p_data.get(k) is None else f(p_data[k])) for k, f in FORMAT.items()}
    values.update({copy: values[orig] for copy, orig in COPIES.items()})
    writer = PdfWriter(clone_from=PdfReader(io.BytesIO(form())))
    page = writer.pages[0]
    writer.update_page_form_field_values(page, fit(values, page), auto_regenerate=False, flatten=True)
    writer.remove_annotations(subtypes="/Widget")                  # flattened: no editable fields left
    if "/AcroForm" in writer._root_object:
        del writer._root_object[NameObject("/AcroForm")]
    writer.pages[0].compress_content_streams()
    writer.compress_identical_objects(remove_identicals=True, remove_orphans=True)
    buf = io.BytesIO()
    writer.write(buf)
    return base64.b64encode(buf.getvalue()).decode()
$$;


-- =====================================================================================
--  3. NEW    view      RPT.V_F_PAYSLIP_DOC   (from views/v_f_payslip_doc.sql)
-- =====================================================================================
-- depends_on: V_F_PBI_PAYSLIP, FN_PAYSLIP_PDF

/* =====================================================================================
   V_F_PAYSLIP_DOC - Payslip PDF per employee x finalized actual month (payslip flow)
   =====================================================================================

   HISTORY
   -------
   2026-10-27  Initial version: the payslip PDF (base64) made by APP.FN_PAYSLIP_PDF from
               RPT.V_F_PBI_PAYSLIP, replacing the paginated report export in the flow.

   NOTES
   -----
   * Always filter on "Period_Key" AND "Employee_ID": one row = one PDF, made when the
     row is read (8-9 s each). A SELECT without a filter makes a PDF for every row.
   * Nothing is stored: the PDF exists only in the query result. The flow turns it into
     the email attachment with base64ToBinary().
   * Same rows as RPT.V_F_PBI_PAYSLIP (finalized actual months only).
   * Keys of the object = field names of the fillable form on APP.PAYSLIP_TEMPLATE.
     The mapping follows EuroCham Payslip.rdl, except NSSF (employee part only, decided
     2026-10-27, so the slip adds up to net pay).
   * Read with the view owner's rights: readers need SELECT on this view only, no
     rights on the function or the stage.
   ===================================================================================== */
CREATE OR REPLACE VIEW RPT.V_F_PAYSLIP_DOC (
    "Period_Key"    COMMENT 'Payroll month YYYYMM, e.g. 202610 (filter on it)',
    "Employee_ID"   COMMENT 'Resource ID, e.g. HR-FRA-001 (filter on it)',
    "Employee_Name" COMMENT 'First name and last name',
    "Email"         COMMENT 'Employee email the payslip is sent to',
    "Period_Label"  COMMENT 'Month and year, e.g. October 2026 (email subject and file name)',
    "PDF_Base64"    COMMENT 'Payslip PDF as base64 text; base64ToBinary() in the flow gives the file'
)
COPY GRANTS
COMMENT = 'Payslip PDF (base64) per employee x finalized actual month; filter on Period_Key and Employee_ID'
AS
SELECT
    p."Period_Key",
    p."Employee_ID",
    p."Employee_Name",
    p."Email",
    p."Period_Label",
    APP.FN_PAYSLIP_PDF(OBJECT_CONSTRUCT_KEEP_NULL(
        'Employee_ID',       p."Employee_ID",
        'Period',            p."Month_Full" || '-' || p."Year",
        'Employee_Name',     p."Employee_Name",
        'Employee_Position', p."Employee_Position",
        'Working_Days',      p."Present_Working_Days",
        'Unpaid_Leave',      p."Unpaid_Leave",
        'Seniority_Pay',     p."Seniority_Pay",
        'Bonus',             p."Annual_Bonus",
        'Gross_USD',         p."Gross_Compensation",
        'Total_Benefit',     p."Seniority_Pay" + p."Annual_Bonus",
        'Taxable_USD',       p."ToS_Taxable_Base",
        'Tax_USD',           p."ToS_Withheld",
        'NSSF_Deductions',   p."NSSF_EE_Total",
        'Net_Pay_USD',       p."Net_Salary_Bank",
        'ECCC_Pct',          p."ECCC_Pct",
        'CCIFC_Pct',         p."CCIFC_Pct",
        'EU_Gate_Pct',       p."EU_Gate_Pct",
        'ECCC_Amount',       p."ECCC_Fund",
        'CCIFC_Amount',      p."CCIFC_Fund",
        'EU_Gate_Amount',    p."EU_Gate_Fund",
        'FX_Rate',           p."FX_USD_KHR",
        'Gross_KHR',         p."Gross_Compensation_KHR",
        'Dep_Count',         p."Dep_Count",
        'Dependents_KHR',    p."Dep_Count" * 150000,
        'Tax_KHR',           p."ToS_Withheld_KHR",
        'Taxable_KHR',       p."ToS_Taxable_Base_KHR",
        'Tax_Rate',          p."ToS_Rate"
    ))                      AS "PDF_Base64"
FROM RPT.V_F_PBI_PAYSLIP p;


-- =====================================================================================
--  4. FIX    view      RPT.V_D_EMPLOYEE (employee register query)   (from views/v_d_employee.sql)
-- =====================================================================================
-- depends_on: T_D_EMPLOYEE, T_D_EMPLOYEE_CONTRACT, T_D_SCENARIO, T_F_SCENARIO_PERIOD

/* =====================================================================================
   V_D_EMPLOYEE - Employee dimension, SCD Type 2: one row per contract version
   =====================================================================================

   HISTORY
   -------
   2026-09-29  Initial version (split from the original build scripts for Git / schemachange).
   2026-10-05  V_D_EMPLOYEE: NON_RESIDENT_FROM and NON_RESIDENT_TO added.
   2026-10-05  V_D_EMPLOYEE: PHONE added (shown and edited on the Employee Register).
   2026-10-06  V_D_EMPLOYEE: BANK_NAME, BANK_ACCOUNT_NAME, BANK_ACCOUNT_NUMBER added; every app
               user may see them, so the Employee Register reads them with the employee list.
   2026-10-07  V_D_EMPLOYEE: IS_CURRENT_VERSION now marks exactly one version per employee,
               based on the calendar month: the version in force this month; else the latest
               version already started (contract ended: the employee stays on the Employee
               Register); else the earliest upcoming one (future start). Before, it was the
               version without an end month, so employees whose contract had ended had no
               current row and disappeared from the register.
   2026-10-19  Own file for DLSync (was in R__views_core.sql): names qualified with ${DB},
               COPY GRANTS keeps the app's SELECT grant when the view is replaced.
   2026-10-28  V_D_EMPLOYEE: IS_CURRENT_VERSION is based on the open payroll month (OPEN or
               IN_APPROVAL in the actual scenario), the calendar month only when no month is
               open. Before, a contract change from the open month stayed hidden on the
               Employee Register until the calendar reached that month.
   ===================================================================================== */
/* IS_CURRENT_VERSION (one TRUE row per employee), with M = the open payroll month (the
   current calendar month when no month is open):
   1. the version with VALID_FROM <= M <= VALID_TO (in force this month);
   2. if none: the version that started last before M (the contract has ended);
   3. if none has started: the version that starts first (future start).
   Versions never overlap, so among the versions already started the latest one is the
   version in force when there is one: rules 1 and 2 are the same ordering. */
CREATE OR REPLACE VIEW RPT.V_D_EMPLOYEE
COPY GRANTS
COMMENT = 'Employee dimension, SCD Type 2: one row per contract version. IS_CURRENT_VERSION marks one version per employee (in force in the open payroll month, or this calendar month when none is open; else the latest started, else the first upcoming). Includes the employee''s bank details.'
AS
WITH m AS (
    -- One row even without an actual scenario (aggregate without GROUP BY)
    SELECT COALESCE(MAX(IFF(p.PERIOD_STATUS IN ('OPEN', 'IN_APPROVAL'), p.PERIOD_KEY, NULL)),
                    TO_NUMBER(TO_CHAR(CURRENT_DATE(), 'YYYYMM'))) AS MONTH_KEY
    FROM APP.T_D_SCENARIO s
    LEFT JOIN APP.T_F_SCENARIO_PERIOD p ON p.SCENARIO_ID = s.SCENARIO_ID
    WHERE s.SCENARIO_TYPE = 'ACTUAL'
)
SELECT
    c.CONTRACT_ID                                           AS EMPLOYEE_VERSION_KEY,
    e.EMPLOYEE_ID,
    e.RESOURCE_CODE,
    e.FIRST_NAME,
    e.LAST_NAME,
    TRIM(COALESCE(e.FIRST_NAME, '') || ' ' || COALESCE(e.LAST_NAME, '')) AS FULL_NAME,
    e.EMAIL,
    e.PHONE,
    e.BANK_NAME,
    e.BANK_ACCOUNT_NAME,
    e.BANK_ACCOUNT_NUMBER,
    e.NATIONALITY,
    e.EMPLOYMENT_START_DATE,
    e.EMPLOYMENT_END_DATE,
    e.IS_ACTIVE                                             AS IS_ACTIVE_EMPLOYEE,
    e.IS_PLANNED,
    e.PLANNED_SCENARIO_ID,
    c.VALID_FROM_PERIOD_KEY,
    COALESCE(c.VALID_TO_PERIOD_KEY, 999912)                 AS VALID_TO_PERIOD_KEY,
    (ROW_NUMBER() OVER (
        PARTITION BY c.EMPLOYEE_ID
        ORDER BY
            -- versions already started first ...
            IFF(c.VALID_FROM_PERIOD_KEY <= m.MONTH_KEY, 0, 1),
            -- ... the latest started one; if none has started, the first upcoming one
            IFF(c.VALID_FROM_PERIOD_KEY <= m.MONTH_KEY,
                -c.VALID_FROM_PERIOD_KEY, c.VALID_FROM_PERIOD_KEY),
            c.CONTRACT_ID DESC
     ) = 1)                                                 AS IS_CURRENT_VERSION,
    c.POSITION,
    c.EMPLOYMENT_TYPE,
    c.CONTRACT_TYPE,
    c.ENTITY_CODE,
    c.MONTHLY_SALARY_USD,
    c.TAX_STATUS,
    c.NON_RESIDENT_FROM,
    c.NON_RESIDENT_TO,
    c.DEPENDANT_CHILDREN,
    c.DEPENDANT_SPOUSE,
    c.DEPENDANT_CHILDREN + c.DEPENDANT_SPOUSE               AS TOTAL_DEPENDANTS,
    c.INSURANCE_USD,
    c.VISA_USD,
    c.WORK_PERMIT_USD,
    c.FRINGE_BENEFIT_USD
FROM APP.T_D_EMPLOYEE e
JOIN APP.T_D_EMPLOYEE_CONTRACT c ON c.EMPLOYEE_ID = e.EMPLOYEE_ID
CROSS JOIN m;
