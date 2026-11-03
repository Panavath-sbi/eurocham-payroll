"""Render the DDL scripts (`{{ key }}` placeholders + config.yml) and run them in dependency order.

Everything runs in the order of DEPLOY_ORDER below: tables -> views -> procedures, dependencies first.
A new script is added to the list by hand. Before every run, deploy.py checks that the list matches the folders (no script
missing, none unknown) and that no script is listed before one named in its `-- depends_on:` line.

Terminal (needs: pip install pyyaml):
    python deploy.py uat                          # print every rendered script, in order (nothing runs)
    python deploy.py uat tables                   # one folder       (or one script: t_d_entity)
    python deploy.py uat views --run -c myconn    # run it (Snowpark, connection from the Snowflake CLI config)
    python deploy.py prod --run -c prodconn       # run everything
    python deploy.py prod --verify -c prodconn    # only the verification (read-only)
GitHub Actions: no -c; the connection comes from the SNOWFLAKE_ACCOUNT / _USER / _PASSWORD environment variables.

Every run ends with a read-only verification: every DEPLOY_ORDER object exists, every view compiles, and APP / RPT
hold nothing else. It prints DEPLOYMENT CONFIRMED, or DEPLOYMENT NOT CONFIRMED and stops with an error.

Snowsight (Workspace with this folder uploaded): set ENV / ONLY / RUN below and press Run on this file.
"""
import io
import os
import re
import sys

import yaml

ENV = 'prod'                          # Change this to 'prod' when deploying to production
ONLY = None                           # Snowsight: None = everything, or e.g. ['views'] / ['t_d_entity']
RUN = True                            # Snowsight: False = print only(dry-run), True = execute (run all the objects)

HERE = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd()
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
]
SCHEMA = {'tables': 'APP', 'views': 'RPT', 'procedures': 'APP', 'stages': 'APP', 'functions': 'APP'}   # fixed in the scripts
DEPENDS = re.compile(r'^--\s*depends_on:\s*(.*)$', re.M)


def render(text, cfg):
    """Replace every {{ key }} with cfg[key]; a missing key stops the run."""
    def sub(m):
        if m.group(1) not in cfg:
            raise KeyError(f"Config key '{m.group(1)}' not found. Available: {sorted(cfg)}")
        return str(cfg[m.group(1)])
    return re.sub(r'\{\{\s*(\w+)\s*\}\}', sub, text)


def check_order():
    """DEPLOY_ORDER must match the folders and respect every `-- depends_on:` line."""
    listed = set(DEPLOY_ORDER)
    on_disk = {f'{d}/{n}' for d in ('tables', 'views', 'procedures') for n in os.listdir(os.path.join(HERE, d)) if n.endswith('.sql')}
    problems = [f'not in DEPLOY_ORDER: {f}' for f in sorted(on_disk - listed)]
    problems += [f'listed but missing: {f}' for f in sorted(listed - on_disk)]
    problems += [f'listed twice: {f}' for f in sorted({f for f in DEPLOY_ORDER if DEPLOY_ORDER.count(f) > 1})]
    pos = {os.path.basename(f)[:-4]: i for i, f in enumerate(DEPLOY_ORDER)}
    for i, f in enumerate(DEPLOY_ORDER):
        if f not in on_disk:
            continue
        with open(os.path.join(HERE, f), encoding='utf-8') as fh:
            m = DEPENDS.search(fh.read(2000))
        for d in ([x.strip().lower() for x in m.group(1).split(',')] if m else []):
            if d in pos and pos[d] > i:
                problems.append(f'{f} is listed before {d}, which it depends on')
    if problems:
        raise ValueError('DEPLOY_ORDER problems:\n  ' + '\n  '.join(problems))


def plan(only=None):
    """Scripts in run order, optionally limited to folders (tables/views/procedures) and/or script names."""
    if not only:
        return list(DEPLOY_ORDER)
    want = [o.lower().removesuffix('.sql') for o in only]
    out = [f for f in DEPLOY_ORDER if f.split('/')[0] in want or os.path.basename(f)[:-4] in want]
    known = {x for f in DEPLOY_ORDER for x in (f.split('/')[0], os.path.basename(f)[:-4])}
    bad = [o for o in want if o not in known]
    if bad:
        raise ValueError(f'Unknown: {bad}. Folders: tables, views, procedures')
    return out


def load_cfg(env):
    with open(os.path.join(HERE, 'config.yml'), encoding='utf-8') as f:
        cfg = yaml.safe_load(f)
    if env not in cfg:
        raise KeyError(f'No environment {env!r} in config.yml (has: {", ".join(cfg)})')
    return cfg[env]


def render_all(env, only=None):
    check_order()
    cfg = load_cfg(env)
    out = {}
    for f in plan(only):                              # render everything before running anything
        with open(os.path.join(HERE, f), encoding='utf-8') as fh:
            out[f] = render(fh.read(), cfg)
    return out


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


def verify(env, session=None):
    """Read-only check of the whole deployment (all of DEPLOY_ORDER). Prints the VERIFY block; returns True if confirmed."""
    session = session or get_session()
    cfg = load_cfg(env)
    db = cfg['database']
    session.sql(f'USE ROLE "{cfg["role_owner"]}"').collect()
    expected = {kind: set() for kind in SCHEMA}                      # file name = object name
    for f in DEPLOY_ORDER:
        kind, name = f.split('/')
        expected[kind].add(name[:-4].upper())
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
    print(f'DEPLOYMENT CONFIRMED ({env}): all {len(DEPLOY_ORDER)} objects verified in {db}.')
    return True


def deploy_all(env='uat', only=None, run=False, session=None):
    """Dry run unless run=True. Runs through the Snowpark session (the active one in Snowsight), then verifies."""
    rendered = render_all(env, only)
    if not run:
        for name, sql in rendered.items():
            print(f'\n-- ===== {name} ({env}) =====\n{sql}')
        return
    from snowflake.connector.util_text import split_statements     # keeps $$ bodies whole
    session = session or get_session()
    cfg = load_cfg(env)                                              # procedure files carry no USE lines: set role and database here
    session.sql(f'USE ROLE "{cfg["role_owner"]}"').collect()
    session.sql(f'USE DATABASE {cfg["database"]}').collect()
    for name, sql in rendered.items():
        print(f'\n{name} ({env})')
        for stmt, _ in split_statements(io.StringIO(sql), remove_comments=True):
            stmt = stmt.strip()
            if stmt:
                print(f"  {' '.join(stmt.split())[:80]} ...")
                session.sql(stmt).collect()                          # raises and stops on failure
    if not verify(env, session):
        raise RuntimeError(f'DEPLOYMENT NOT CONFIRMED ({env})')


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('env')
    ap.add_argument('only', nargs='*', help='folders (tables/views/procedures) or script names; default: all')
    ap.add_argument('--run', action='store_true', help='execute, then verify (default: only print)')
    ap.add_argument('--verify', action='store_true', help='only verify what is deployed (read-only)')
    ap.add_argument('-c', '--connection', help='connection name from the Snowflake CLI config (not needed in GitHub Actions)')
    if len(sys.argv) < 2 or sys.argv[1].startswith('-'):     # no terminal arguments (Snowsight): use the settings above
        return deploy_all(ENV, ONLY, RUN)
    a = ap.parse_args()
    if a.verify:
        sys.exit(0 if verify(a.env, get_session(a.connection)) else 1)
    if not a.run:
        return deploy_all(a.env, a.only or None)
    try:
        deploy_all(a.env, a.only or None, run=True, session=get_session(a.connection))
    except Exception as e:
        sys.exit(f'FAILED: {first_line(e)}')


if __name__ == '__main__':
    main()
