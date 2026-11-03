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

FORM_PATH = "@{{ database }}.APP.PAYSLIP_TEMPLATE/payslip_fillable.pdf"
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
