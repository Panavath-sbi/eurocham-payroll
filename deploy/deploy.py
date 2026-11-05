"""Deploy ddl/ (object definitions) and dml/ (everything else) to one environment, each file once.

ddl/<kind>/<object>.sql  1 file = 1 object: CREATE OR REPLACE only; no USE, no {{ }}, no DML or GRANT.
                         Runs in DEPLOY_ORDER (dependencies first; `-- depends_on:` is checked).
dml/<object>_<action>.sql  e.g. t_d_period_insert.sql
                         DML, grants, data fixes, one-off changes (ALTER, DROP). Runs after ddl/, in file-name order.
                         A dml file is tracked by its name: renaming one that already ran makes it run again.

What runs is decided by APP.T_F_DEPLOY_HISTORY (script + checksum of every file that ran):
  never ran                           -> runs
  ran, unchanged                      -> skipped
  ran, changed: views / procedures / functions  -> runs again (CREATE OR REPLACE ... COPY GRANTS keeps grants)
  ran, changed: tables / stages / dml -> BLOCKED, nothing runs (a rerun would wipe rows / files, or repeat a change):
                                         put the change in a new dml/ script instead (ALTER TABLE, UPDATE, ...)
deploy.py sets the role and database itself (config.yml), since the files have no USE lines.

Terminal (needs: pip install pyyaml snowflake-snowpark-python):
    python deploy/deploy.py uat                          # dry run: what would run (reads the history with -c)
    python deploy/deploy.py uat -c myconn --show         # ... and print the SQL
    python deploy/deploy.py uat --run -c myconn          # run what is pending, then verify
    python deploy/deploy.py prod --verify -c prodconn    # only the verification (read-only)
    python deploy/deploy.py prod --init -c prodconn      # release check: dry run; first creates the history from main
First deployment (prod, built by hand, no history): the release check (--init) creates APP.T_F_DEPLOY_HISTORY and records
every file as it is on main (origin/main, what prod was built from) as run, executing nothing. From then on:
  dml / tables / stages on main         -> never run again
  views / procedures / functions        -> run again only when the release changed them
  files not on main (new)               -> run
A table / stage that exists but has no history row is BLOCKED: CREATE OR REPLACE would wipe its rows / files.
GitHub Actions: no -c; the connection comes from the SNOWFLAKE_ACCOUNT / _USER / _PASSWORD environment variables.

Every run ends with a read-only verification: every DEPLOY_ORDER object exists, every view compiles, and APP / RPT
hold nothing else. It prints DEPLOYMENT CONFIRMED, or DEPLOYMENT NOT CONFIRMED and stops with an error.

Snowsight (Workspace with the repository uploaded, ddl/ and dml/): set ENV / RUN below and press Run on this file.
"""
import hashlib
import io
import os
import re
import subprocess
import sys

import yaml

ENV = 'uat'                           # Snowsight: 'uat' or 'prod'
RUN = False                           # Snowsight: False = dry run (what would run), True = run what is pending

HERE = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd()
DDL = os.path.join(HERE, '..', 'ddl')
DML = os.path.join(HERE, '..', 'dml')
DEPLOY_ORDER = [                      # run order; a new script is added here (dependencies first)
    # --- tables ---
    'tables/t_d_app_user.sql',
    'tables/t_d_department.sql',
    'tables/t_d_entity.sql',
    'tables/t_d_period.sql',
    'tables/t_d_fund.sql',
    'tables/t_d_pay_component.sql',
    'tables/t_f_change_log.sql',
    'tables/t_d_scenario.sql',
    'tables/t_f_payslip_run.sql',
    'tables/t_p_approval_step.sql',
    'tables/t_p_statutory_parameter.sql',
    'tables/t_p_tax_bracket.sql',
    'tables/t_d_employee.sql',
    'tables/t_f_approval.sql',
    'tables/t_f_scenario_period.sql',
    'tables/t_d_employee_contract.sql',
    'tables/t_f_department_allocation.sql',
    'tables/t_f_fund_allocation.sql',
    'tables/t_f_payroll_input.sql',
    'tables/t_f_payroll_line.sql',
    'tables/t_d_scenario_employee.sql',
    # --- views ---
    'views/v_d_app_user.sql',
    'views/v_d_employee.sql',
    'views/v_d_lookup.sql',
    'views/v_d_pbi_employee.sql',
    'views/v_d_pbi_employee_details.sql',
    'views/v_d_pbi_signature.sql',
    'views/v_d_period.sql',
    'views/v_d_scenario.sql',
    'views/v_d_scenario_employee.sql',
    'views/v_f_allocation.sql',
    'views/v_f_approval_event.sql',
    'views/v_f_approval_progress.sql',
    'views/v_f_payroll_summary.sql',
    'views/v_f_payroll_input.sql',
    'views/v_f_payroll_line.sql',
    'views/v_f_payslip_due.sql',
    'views/v_f_pbi_payroll.sql',
    'views/v_f_pbi_payslip.sql',
    'views/v_f_scenario_period.sql',
    'views/v_p_approval_step.sql',
    'views/v_p_pbi_employee_params.sql',
    'views/v_p_statutory_parameter.sql',
    'views/v_f_pbi_payroll_approval.sql',
    'views/v_f_budget_vs_actual.sql',
    'views/v_f_cost_allocation.sql',
    'views/v_f_dashboard_kpi.sql',
    'views/v_f_payroll_month.sql',
    'views/v_f_scenario_summary.sql',
    'views/v_f_dashboard_month.sql',
    'views/v_f_cost_center_summary.sql',
    # --- procedures ---
    'procedures/sp_approve_step.sql',
    'procedures/sp_calc_period.sql',
    'procedures/sp_delete_planned_hire.sql',
    'procedures/sp_delete_scenario.sql',
    'procedures/sp_finalize_payroll.sql',
    'procedures/sp_finish_payslip_run.sql',
    'procedures/sp_reject_step.sql',
    'procedures/sp_reset_approvals.sql',
    'procedures/sp_save_approval_steps.sql',
    'procedures/sp_set_employee_check.sql',
    'procedures/sp_start_payslip_run.sql',
    'procedures/sp_undo_approval.sql',
    'procedures/sp_calculate_payroll.sql',
    'procedures/sp_create_forecast.sql',
    'procedures/sp_create_scenario.sql',
    'procedures/sp_open_payroll_period.sql',
    'procedures/sp_save_monthly_input.sql',
    'procedures/sp_save_planned_hire.sql',
    'procedures/sp_save_scenario_employee.sql',
    'procedures/sp_submit_scenario.sql',
    'procedures/sp_save_department_allocation.sql',
    'procedures/sp_save_employee.sql',
    'procedures/sp_save_employee_contract.sql',
    'procedures/sp_save_exchange_rate.sql',
    'procedures/sp_save_fund_allocation.sql',
    'procedures/sp_save_statutory_parameter.sql',
    'procedures/sp_save_working_days.sql',
    'procedures/sp_set_employee_active.sql',
    # --- stages (run once; the files in them are uploaded by hand) ---
    'stages/payslip_template.sql',
    # --- functions ---
    'functions/fn_payslip_pdf.sql',             # reads the payslip_template stage
    'views/v_f_payslip_doc.sql',                # uses FN_PAYSLIP_PDF
]
SCHEMA = {'tables': 'APP', 'views': 'RPT', 'procedures': 'APP', 'stages': 'APP', 'functions': 'APP'}   # fixed in the scripts
REPEATABLE = {'views', 'procedures', 'functions'}                   # CREATE OR REPLACE is safe to run again
HISTORY = 'T_F_DEPLOY_HISTORY'                                       # in APP; deploy.py's own bookkeeping, not a ddl object
BUILT_FROM = 'origin/main'                                          # --init: what prod was built from (by hand)
DEPENDS = re.compile(r'^--\s*depends_on:\s*(.*)$', re.M)


def code(text):
    """The SQL without comments and $$ bodies (a procedure's own DML is not a rule break)."""
    text = re.sub(r'\$\$.*?\$\$', '$$', text, flags=re.S)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'--[^\n]*', '', text)


def check_files():
    """DEPLOY_ORDER must match the folders and the depends_on lines; every file must follow its folder's rules."""
    listed = set(DEPLOY_ORDER)
    on_disk = {f'{d}/{n}' for d in SCHEMA if os.path.isdir(os.path.join(DDL, d))
               for n in os.listdir(os.path.join(DDL, d)) if n.endswith('.sql')}
    problems = [f'not in DEPLOY_ORDER: {f}' for f in sorted(on_disk - listed)]
    problems += [f'listed but missing: {f}' for f in sorted(listed - on_disk)]
    problems += [f'listed twice: {f}' for f in sorted({f for f in DEPLOY_ORDER if DEPLOY_ORDER.count(f) > 1})]
    pos = {os.path.basename(f)[:-4]: i for i, f in enumerate(DEPLOY_ORDER)}
    for i, f in enumerate(DEPLOY_ORDER):
        if f not in on_disk:
            continue
        text = read(f'ddl/{f}')
        m = DEPENDS.search(text[:2000])
        for d in ([x.strip().lower() for x in m.group(1).split(',')] if m else []):
            if d in pos and pos[d] > i:
                problems.append(f'{f} is listed before {d}, which it depends on')
        c = code(text)
        if not c.rstrip().endswith(';'):
            problems.append(f'{f}: does not end with ; (file cut off?)')
        if '{{' in re.sub(r'--[^\n]*|/\*.*?\*/', '', text, flags=re.S):   # also inside $$ bodies: nothing renders it
            problems.append(f'{f}: placeholder {{{{ }}}} (ddl files use real names)')
        if re.search(r'^\s*(USE|INSERT|MERGE|UPDATE|DELETE|TRUNCATE|GRANT|ALTER|EXECUTE\s+IMMEDIATE)\b', c, re.M | re.I):   # not EXECUTE AS CALLER
            problems.append(f'{f}: only the CREATE of the object belongs here; USE / DML / GRANT / ALTER go in dml/ (DROP + CREATE only when CREATE OR REPLACE is not possible)')
        if len(re.findall(r'^\s*CREATE\b', c, re.M | re.I)) != 1:
            problems.append(f'{f}: must hold exactly one CREATE')
    for f in dml_files():
        if re.search(r'^\s*CREATE\s+OR\s+REPLACE\b', code(read(f)), re.M | re.I):
            problems.append(f'{f}: object definitions belong in ddl/')
    if problems:
        raise ValueError('File problems:\n  ' + '\n  '.join(problems))


def dml_files():
    return [f'dml/{n}' for n in sorted(os.listdir(DML)) if n.endswith('.sql')] if os.path.isdir(DML) else []


def read(script):
    with open(os.path.join(HERE, '..', script), encoding='utf-8') as fh:
        return fh.read()


def checksum(text):
    return hashlib.md5('\n'.join(l.rstrip() for l in text.strip().splitlines()).encode()).hexdigest()   # line endings don't count


def scripts():
    """Every script in run order: ddl/ (DEPLOY_ORDER), then dml/ (name order)."""
    return [f'ddl/{f}' for f in DEPLOY_ORDER] + dml_files()


def load_cfg(env):
    with open(os.path.join(HERE, 'config.yml'), encoding='utf-8') as f:
        cfg = yaml.safe_load(f)
    if env not in cfg:
        raise KeyError(f'No environment {env!r} in config.yml (has: {", ".join(cfg)})')
    return cfg[env]


def first_line(e):
    """The error on one line, max 300 characters."""
    return ' '.join(str(e).split())[:300] or type(e).__name__


def get_session(connection=None):
    """Snowsight: the active session. Terminal: the named connection (-c). GitHub Actions: the SNOWFLAKE_* environment variables."""
    from snowflake.snowpark import Session
    if connection:
        return Session.builder.config('connection_name', connection).create()
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        return Session.builder.configs({k: os.environ[f'SNOWFLAKE_{k.upper()}'] for k in ('account', 'user', 'password')}).create()


def use_env(session, cfg):
    session.sql(f'USE ROLE "{cfg["role_owner"]}"').collect()
    session.sql(f'USE DATABASE {cfg["database"]}').collect()


def history(session, create=False):
    """{script: checksum of its last run}; empty when the history table does not exist yet."""
    if create:
        session.sql(f'CREATE TABLE IF NOT EXISTS APP.{HISTORY} (SCRIPT TEXT NOT NULL, CHECKSUM TEXT NOT NULL, '
                    'APPLIED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP::TIMESTAMP_NTZ, APPLIED_BY TEXT DEFAULT CURRENT_USER, '
                    "GIT_COMMIT TEXT, ACTION TEXT) COMMENT = 'Scripts run by deploy.py: one row per run of a script (RUN or BASELINE)'").collect()
    try:
        rows = session.sql(f'SELECT SCRIPT, CHECKSUM FROM APP.{HISTORY} '
                           'QUALIFY ROW_NUMBER() OVER (PARTITION BY SCRIPT ORDER BY APPLIED_AT DESC) = 1').collect()
    except Exception:
        return {}
    return {r[0]: r[1] for r in rows}


def pending(done):
    """(to_run, blocked) for the files on disk against {script: checksum} of what already ran."""
    run, blocked = [], []
    for s in scripts():
        h = checksum(read(s))
        if s not in done:
            run.append((s, h))
        elif done[s] != h:
            (run if s.split('/')[1] in REPEATABLE else blocked).append((s, h))
    return run, blocked


def record(session, script, h, action, commit=None):
    session.sql(f'INSERT INTO APP.{HISTORY} (SCRIPT, CHECKSUM, GIT_COMMIT, ACTION) SELECT ?, ?, ?, ?',
                params=[script, h, commit or os.environ.get('GITHUB_SHA'), action]).collect()


def git(*args):
    r = subprocess.run(['git', *args], cwd=os.path.join(HERE, '..'), capture_output=True)
    return r.stdout.decode('utf-8') if r.returncode == 0 else None


def init_history(session, ref=BUILT_FROM):
    """--init: while APP.T_F_DEPLOY_HISTORY is empty, create it and record every file as it is in git `ref` as run.
    Runs nothing; a no-op once the history has rows. Returns the history."""
    if done := history(session, create=True):
        return done
    sha = git('rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}')
    if not sha:
        raise ValueError(f'git ref {ref} not found (the checkout needs fetch-depth: 0)')
    n = 0
    for s in scripts():                                              # a file that is not in ref is new: it stays pending
        if (text := git('show', f'{ref}:{s}')) is not None:
            record(session, s, checksum(text), 'BASELINE', sha.strip())
            n += 1
    print(f'HISTORY: APP.{HISTORY} created; {n} scripts recorded as run from {ref} ({sha.strip()[:7]}); nothing was executed.')
    return history(session)


def verify(env, session=None):
    """Read-only check of the whole deployment (all of DEPLOY_ORDER). Prints the VERIFY block; returns True if confirmed."""
    session = session or get_session()
    cfg = load_cfg(env)
    db = cfg['database']
    use_env(session, cfg)
    expected = {kind: set() for kind in SCHEMA}                      # file name = object name
    for f in DEPLOY_ORDER:
        kind, name = f.split('/')
        expected[kind].add(name[:-4].upper())
    expected['tables'].add(HISTORY)                                  # deploy.py's own table: counted, never unexpected
    found, report = {}, []                                           # report: (label, ok, total, issues)
    for kind in SCHEMA:
        try:                                                         # SHOW lists what the role can see; no warehouse needed
            rows = session.sql(f'SHOW {kind.upper()} IN SCHEMA {db}.{SCHEMA[kind]}').collect()
            found[kind], issues = {str(r['name']).upper() for r in rows if r.as_dict().get('is_builtin') != 'Y'}, []
        except Exception as e:
            found[kind], issues = set(), [f'cannot list: {first_line(e)}']
        missing = sorted(expected[kind] - found[kind])
        report.append((f'{kind} in {SCHEMA[kind]}', len(expected[kind]) - len(missing), len(expected[kind]),
                       issues or ([f"missing: {', '.join(missing)}"] if missing else [])))
    views, broken = sorted(expected['views'] & found['views']), []
    for v in views:
        try:
            session.sql(f'SELECT * FROM {db}.RPT.{v} LIMIT 0').collect()   # compiles the view, reads no rows
        except Exception as e:
            broken.append(f'{v} ({first_line(e)})')
    report.append(('views compile', len(views) - len(broken), len(expected['views']), [f"broken: {'; '.join(broken)}"] if broken else []))
    extra = sorted(f'{kind[:-1]} {n}' for kind in SCHEMA for n in found[kind] - expected[kind])   # leftover or duplicate objects

    print(f'\nVERIFY ({env}): {db}')
    for label, ok, total, issues in report:
        print(f'  {label:<18}{ok}/{total}' + (f"   {'; '.join(issues)}" if issues else ''))
    print(f"  {'unexpected':<18}{', '.join(extra) if extra else 'none'}")
    if extra or any(issues for *_, issues in report):
        print(f'DEPLOYMENT NOT CONFIRMED ({env}): see the lines above.')
        return False
    print(f'DEPLOYMENT CONFIRMED ({env}): all {sum(map(len, expected.values()))} objects verified in {db}.')
    return True


def live(session, cfg):
    """'tables/T_D_EMPLOYEE', 'stages/PAYSLIP_TEMPLATE', ...: the run-once objects that exist (a rerun would wipe them)."""
    found = set()
    for kind in set(SCHEMA) - REPEATABLE:
        try:
            rows = session.sql(f"SHOW {kind.upper()} IN SCHEMA {cfg['database']}.{SCHEMA[kind]}").collect()
            found |= {f"{kind}/{str(r['name']).upper()}" for r in rows}
        except Exception:                                            # no schema yet: nothing exists
            pass
    return found


def deploy_all(env='uat', run=False, session=None, show=False, init=False):
    """Dry run unless run. init (release check): a dry run that first creates the history from main when it is empty
    (init_history), so the check shows only what the release changes. Without a session nothing is read."""
    check_files()
    cfg = load_cfg(env)
    if session is not None:
        use_env(session, cfg)
    if session is None:
        done = {}
    else:
        done = init_history(session) if init else history(session, create=run)
    to_run, blocked = pending(done)
    exists = live(session, cfg) if session is not None else set()
    clash = [(s, h) for s, h in to_run if f"{s.split('/')[1]}/{os.path.basename(s)[:-4].upper()}" in exists]   # dml never matches
    to_run = [x for x in to_run if x not in clash]                   # CREATE OR REPLACE on a live table / stage wipes it
    unchanged = len(scripts()) - len(to_run) - len(blocked) - len(clash)
    print(f"\n{env} ({cfg['database']}): {len(to_run)} to run, {len(blocked) + len(clash)} blocked, {unchanged} unchanged"
          + ('' if session else ' (history not read: no connection)'))
    for s, _ in blocked:
        print(f'  BLOCKED  {s}: changed after it ran; put the change in a new dml/ script')
    for s, _ in clash:
        print(f'  BLOCKED  {s}: exists but has no history row; running it would wipe it (run the release check, --init, first)')
    blocked += clash
    if blocked:
        raise RuntimeError(f'{len(blocked)} script(s) blocked; nothing was run')
    for s, _ in to_run:
        print(f'  {"run" if run else "would run"}  {s}')
        if show and not run:
            print(read(s))
    if not run:
        if session is not None and not verify(env, session) and not to_run:   # state shown; missing objects are fine
            raise RuntimeError(f'DEPLOYMENT NOT CONFIRMED ({env}) with nothing pending')   # while they are still to run
        return
    from snowflake.connector.util_text import split_statements     # keeps $$ bodies whole
    for s, h in to_run:
        print(f'\n{s} ({env})')
        for stmt, _ in split_statements(io.StringIO(read(s)), remove_comments=True):
            stmt = stmt.strip()
            if stmt:
                print(f"  {' '.join(stmt.split())[:80]} ...")
                session.sql(stmt).collect()                          # raises and stops on failure
        record(session, s, h, 'RUN')                                 # recorded only after the whole file ran
    if not verify(env, session):
        raise RuntimeError(f'DEPLOYMENT NOT CONFIRMED ({env})')


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('env')
    ap.add_argument('--run', action='store_true', help='run what is pending, then verify (default: dry run)')
    ap.add_argument('--verify', action='store_true', help='only verify what is deployed (read-only)')
    ap.add_argument('--show', action='store_true', help='dry run: also print the SQL that would run')
    ap.add_argument('--init', action='store_true', help='release check: dry run; while the history is empty, first create it from origin/main (runs nothing)')
    ap.add_argument('-c', '--connection', help='connection name from the Snowflake CLI config (not needed in GitHub Actions)')
    if len(sys.argv) < 2 or sys.argv[1].startswith('-'):     # no terminal arguments (Snowsight): use the settings above
        return deploy_all(ENV, RUN, get_session())
    a = ap.parse_args()
    try:
        if a.verify:
            sys.exit(0 if verify(a.env, get_session(a.connection)) else 1)
        connect = a.run or a.init or a.connection or os.environ.get('GITHUB_ACTIONS')
        deploy_all(a.env, a.run, get_session(a.connection) if connect else None, a.show, a.init)
    except Exception as e:
        sys.exit(f'FAILED: {first_line(e)}')


if __name__ == '__main__':
    main()
