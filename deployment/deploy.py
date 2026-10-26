"""Deploy the EuroCham DDL scripts in DEPLOY_ORDER, then verify all of them. Details: README.md.

Snowsight: set ENV / ONLY / RUN / VERIFY below and press Run.
GitHub Actions: python deploy.py <env> [script ...]   (session from the SNOWFLAKE_* secrets)
"""
import io
import os
import re
import sys

import yaml
from snowflake.connector.util_text import split_statements           # keeps $$ bodies whole

ENV = 'uat'                           # a block in config.yml: 'uat' or 'prod'
ONLY = None                           # None = everything, or e.g. ['views'] / ['t_d_entity']
RUN = False                           # False = dry run (print only), True = execute
VERIFY = False                        # with RUN = False: True = only check (read-only)

SCHEMA = {'tables': 'APP', 'views': 'RPT', 'procedures': 'APP'}      # fixed in the scripts
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
DEPENDS = re.compile(r'^--\s*depends_on:\s*(.*)$', re.M)
DESTRUCTIVE = re.compile(r'\b(?:CREATE\s+OR\s+REPLACE\s+TABLE|DROP\s+TABLE|TRUNCATE\b|DELETE\s+FROM\s+[\w.]+\s*(?:;|$))', re.I)


def read(f):
    with open(os.path.join(HERE, f), encoding='utf-8') as fh:
        return fh.read()


def statements(sql):
    """The statements of a script, comments removed."""
    return [s.strip() for s, _ in split_statements(io.StringIO(sql), remove_comments=True) if s.strip()]


def first_line(e):
    return (str(e).strip().splitlines() or [type(e).__name__])[0][:200]


def render(text, cfg):
    """Replace every {{ key }} with cfg[key]; a missing key stops the run (KeyError)."""
    return re.sub(r'\{\{\s*(\w+)\s*\}\}', lambda m: str(cfg[m.group(1)]), text)


def destructive(sql):
    """Statements of a table script that can destroy data; none if the script has an `-- allow: drop` line."""
    if '-- allow: drop' in sql:
        return []
    return [' '.join(hit.group(0).split()) for hit in map(DESTRUCTIVE.search, statements(sql)) if hit]


def check_scripts():
    """DEPLOY_ORDER must match the folders and respect every `-- depends_on:` line; table scripts must not destroy data."""
    listed = set(DEPLOY_ORDER)
    on_disk = {f'{d}/{n}' for d in SCHEMA for n in os.listdir(os.path.join(HERE, d)) if n.endswith('.sql')}
    problems = [f'not in DEPLOY_ORDER: {f}' for f in sorted(on_disk - listed)]
    problems += [f'listed but missing: {f}' for f in sorted(listed - on_disk)]
    pos = {os.path.basename(f)[:-4]: i for i, f in enumerate(DEPLOY_ORDER)}
    for i, f in enumerate(DEPLOY_ORDER):
        if f not in on_disk:
            continue
        text = read(f)
        m = DEPENDS.search(text)
        for d in ([x.strip().lower() for x in m.group(1).split(',')] if m else []):
            if d in pos and pos[d] > i:
                problems.append(f'{f} is listed before {d}, which it depends on')
        if f.startswith('tables/'):
            problems += [f'{f} can destroy data: {s} (add an `-- allow: drop` line if intended)' for s in destructive(text)]
    if problems:
        raise ValueError('Script problems:\n  ' + '\n  '.join(problems))


def plan(only=None):
    """Scripts in run order, optionally limited to folders (tables/views/procedures) and/or script names."""
    if not only:
        return list(DEPLOY_ORDER)
    want = [o.lower().removesuffix('.sql') for o in only]
    known = {x for f in DEPLOY_ORDER for x in (f.split('/')[0], os.path.basename(f)[:-4])}
    if bad := [o for o in want if o not in known]:
        raise ValueError(f'Unknown: {bad}. Folders: tables, views, procedures')
    return [f for f in DEPLOY_ORDER if f.split('/')[0] in want or os.path.basename(f)[:-4] in want]


def load_cfg(env):
    return yaml.safe_load(read('config.yml'))[env]                   # unknown env: KeyError


def render_all(env, only=None):
    check_scripts()
    cfg = load_cfg(env)
    return {f: render(read(f), cfg) for f in plan(only)}             # render everything before running anything


def get_session():
    """Snowsight: the active session. GitHub Actions: a new session from the SNOWFLAKE_* environment variables."""
    from snowflake.snowpark import Session
    from snowflake.snowpark.context import get_active_session
    try:
        return get_active_session()
    except Exception:
        return Session.builder.configs({k: os.environ[f'SNOWFLAKE_{k.upper()}'] for k in ('account', 'user', 'password')}).create()


def verify(env, session=None):
    """Read-only check of the whole deployment: all of DEPLOY_ORDER, not only what was just deployed."""
    session = session or get_session()
    cfg = load_cfg(env)
    db = cfg['database']
    session.sql(f'USE ROLE "{cfg["role_owner"]}"').collect()
    expected = {kind: set() for kind in SCHEMA}                      # file name = object name
    for f in DEPLOY_ORDER:
        kind, name = f.split('/')
        expected[kind].add(name[:-4].upper())
    report, found = [], {}                                           # report: (label, ok, total, issues)
    for kind, names in expected.items():
        where = f'{db}.{SCHEMA[kind]}'
        try:                                                         # SHOW lists what the role can see; no warehouse needed
            found[kind] = {str(r['name']).upper() for r in session.sql(f'SHOW {kind.upper()} IN SCHEMA {where}').collect()}
            issues = []
        except Exception as e:
            found[kind], issues = set(), [f'cannot list {kind} in {where}: {first_line(e)}']
        missing = sorted(names - found[kind])
        issues = issues or ([f"missing: {', '.join(missing)}"] if missing else [])
        report.append((f'{kind} in {SCHEMA[kind]}', len(names) - len(missing), len(names), issues))
    views, broken = sorted(expected['views'] & found['views']), []
    for v in views:
        try:
            session.sql(f'SELECT * FROM {db}.RPT.{v} LIMIT 0').collect()   # compiles the view, reads no rows
        except Exception as e:
            broken.append(f'{v} ({first_line(e)})')
    report.append(('views compile', len(views) - len(broken), len(expected['views']), [f"broken: {'; '.join(broken)}"] if broken else []))
    extra = sorted(f'{kind[:-1]} {n}' for kind in SCHEMA for n in found[kind] - expected[kind])   # leftover or duplicate objects

    print(f'VERIFY ({env}): {db}')
    for label, ok, total, issues in report:
        print(f'  {label:<18}{ok}/{total}' + (f"   {'; '.join(issues)}" if issues else ''))
    print(f"  {'unexpected':<18}{', '.join(extra) if extra else 'none'}")
    if extra or any(issues for *_, issues in report):
        print(f'DEPLOYMENT NOT CONFIRMED ({env}): see the lines above.')
        raise RuntimeError(f'DEPLOYMENT NOT CONFIRMED ({env})')
    print(f'DEPLOYMENT CONFIRMED ({env}): all {sum(len(v) for v in expected.values())} objects verified in {db}.')


def deploy_all(env='uat', only=None, run=False, session=None, verify_only=False):
    """Dry run unless run=True; a real run is followed by verify()."""
    rendered = render_all(env, only)
    if verify_only and not run:
        return verify(env, session)
    if not run:
        for name, sql in rendered.items():
            print(f'\n-- ===== {name} ({env}) =====\n{sql}')
        return
    session = session or get_session()
    print(f'DEPLOY ({env}): {len(rendered)} script(s): {", ".join(os.path.basename(f)[:-4] for f in rendered)}')
    for name, sql in rendered.items():
        for stmt in statements(sql):
            try:
                session.sql(stmt).collect()
            except Exception as e:
                raise RuntimeError(f'DEPLOYMENT FAILED ({env}) in {name}: {first_line(e)}') from None
    verify(env, session)                                             # a finished run is not yet a successful deployment


if __name__ == '__main__':
    args = sys.argv[1:]
    if args and not args[0].startswith('-'):                         # GitHub Actions: python deploy.py <env> [script ...]
        deploy_all(args[0], args[1:] or None, run=True)
    else:                                                          # Snowsight: the settings above (no arguments)
        deploy_all(ENV, ONLY, RUN, verify_only=VERIFY)
