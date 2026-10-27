"""Render the DDL scripts (`{{ key }}` placeholders + config.yml) and run them in dependency order.

Everything runs in the order of DEPLOY_ORDER below: tables -> views -> procedures -> stages -> functions -> views that use a function, dependencies first.
A new script is added to the list by hand. Before every run, deploy.py checks that the list matches the folders (no script
missing, none unknown) and that no script is listed before one named in its `-- depends_on:` line.

Terminal / GitHub Actions (needs: pip install pyyaml snowflake-snowpark-python):
    python deploy.py uat                          # print every rendered script, in order (nothing runs)
    python deploy.py uat tables                   # one folder       (or one script: t_d_entity)
    python deploy.py uat views --run -c myconn    # run it with a Snowflake connection (connections.toml)
    python deploy.py prod --run                   # run everything (GitHub Actions: session from the SNOWFLAKE_* secrets)

Snowsight (Workspace with this folder uploaded): set ENV / ONLY / RUN / VERIFY below and press Run on this file.

Every run (RUN / --run) ends with a verification of all of DEPLOY_ORDER: every object exists, every view compiles, and
APP / RPT hold nothing that is not in DEPLOY_ORDER. It prints DEPLOYMENT CONFIRMED, or fails with DEPLOYMENT NOT CONFIRMED.
"""
import io
import os
import re
import sys

import yaml

ENV = 'uat'                          # Change this to 'prod' when deploying to production
ONLY = None                           # Snowsight: None = everything, or e.g. ['views'] / ['t_d_entity']
RUN = True                            # Snowsight: False = print only(dry-run), True = execute (run all the objects)
VERIFY = False                        # Snowsight: with RUN = False, True = only verify an earlier deployment (read-only)

SCHEMA = {'tables': 'APP', 'views': 'RPT', 'procedures': 'APP', 'stages': 'APP', 'functions': 'APP'}   # fixed in the scripts

HERE = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd()
DEPLOY_ORDER = [                      # run order; a new script is added here (dependencies first)
    # --- tables ---
    'tables/t_f_deploy_log.sql',                # first: the deployment log (written at the end of every run)
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
    # --- stages (the files in them are uploaded by hand) ---
    'stages/payslip_template.sql',
    # --- functions ---
    'functions/fn_payslip_pdf.sql',
    # --- views that use a function (after it) ---
    'views/v_f_payslip_doc.sql',
]
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
    on_disk = {f'{d}/{n}' for d in SCHEMA for n in os.listdir(os.path.join(HERE, d)) if n.endswith('.sql')}
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
    """Scripts in run order, optionally limited to folders (see SCHEMA) and/or script names."""
    if not only:
        return list(DEPLOY_ORDER)
    want = [o.lower().removesuffix('.sql') for o in only]
    out = [f for f in DEPLOY_ORDER if f.split('/')[0] in want or os.path.basename(f)[:-4] in want]
    known = {x for f in DEPLOY_ORDER for x in (f.split('/')[0], os.path.basename(f)[:-4])}
    bad = [o for o in want if o not in known]
    if bad:
        raise ValueError(f"Unknown: {bad}. Folders: {', '.join(SCHEMA)}")
    return out


def render_all(env, only=None):
    check_order()
    with open(os.path.join(HERE, 'config.yml'), encoding='utf-8') as f:
        cfg = yaml.safe_load(f)
    if env not in cfg:
        raise KeyError(f'No environment {env!r} in config.yml (has: {", ".join(cfg)})')
    out = {}
    for f in plan(only):                              # render everything before running anything
        with open(os.path.join(HERE, f), encoding='utf-8') as fh:
            out[f] = render(fh.read(), cfg[env])
    return out


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


def first_line(e):
    """The error on one line, max 300 characters (Snowflake puts the detail on the line after 'SQL compilation error:')."""
    return ' '.join(str(e).split())[:300] or type(e).__name__


def load_cfg(env):
    with open(os.path.join(HERE, 'config.yml'), encoding='utf-8') as f:
        return yaml.safe_load(f)[env]


def show_objects(session, db):
    """{kind: set of names} in APP / RPT, and {kind: error} for a kind that could not be listed."""
    found, errors = {}, {}
    for kind in SCHEMA:
        try:                                                         # SHOW lists what the role can see; no warehouse needed
            rows = session.sql(f'SHOW {kind.upper()} IN SCHEMA {db}.{SCHEMA[kind]}').collect()
            found[kind] = {str(r['name']).upper() for r in rows if r.as_dict().get('is_builtin') != 'Y'}   # skip SYSTEM$... procedures
        except Exception as e:
            found[kind], errors[kind] = set(), first_line(e)
    return found, errors


def verify(env, session=None):
    """Read-only check of the whole deployment: all of DEPLOY_ORDER, not only what was just deployed.
    Prints the VERIFY block; returns (confirmed, summary, problems)."""
    session = session or get_session()
    cfg = load_cfg(env)
    db = cfg['database']
    session.sql(f'USE ROLE "{cfg["role_owner"]}"').collect()
    expected = {kind: set() for kind in SCHEMA}                      # file name = object name
    for f in DEPLOY_ORDER:
        kind, name = f.split('/')
        expected[kind].add(name[:-4].upper())
    found, errors = show_objects(session, db)
    report = []                                                      # (label, ok, total, issues)
    for kind, names in expected.items():
        issues = [f'cannot list {kind} in {db}.{SCHEMA[kind]}: {errors[kind]}'] if kind in errors else []
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

    lines = [f'{label} {ok}/{total}' for label, ok, total, _ in report] + [f"unexpected {', '.join(extra) or 'none'}"]
    problems = '; '.join([i for *_, issues in report for i in issues] + ([f"unexpected: {', '.join(extra)}"] if extra else []))

    print(f'\nVERIFY ({env}): {db}')
    for label, ok, total, issues in report:
        print(f'  {label:<18}{ok}/{total}' + (f"   {'; '.join(issues)}" if issues else ''))
    print(f"  {'unexpected':<18}{', '.join(extra) if extra else 'none'}")
    if problems:
        print(f'DEPLOYMENT NOT CONFIRMED ({env}): see the lines above.')
    else:
        print(f'DEPLOYMENT CONFIRMED ({env}): all {sum(len(v) for v in expected.values())} objects verified in {db}.')
    return not problems, '; '.join(lines), problems


def changed_scripts(session, db, env):
    """Scripts changed in git since the last CONFIRMED deployment of env; None without git or without an earlier commit."""
    import subprocess
    try:
        rows = session.sql(f"SELECT GIT_COMMIT FROM {db}.APP.T_F_DEPLOY_LOG WHERE ENV = ? AND STATUS = 'CONFIRMED' "
                           'AND GIT_COMMIT IS NOT NULL ORDER BY FINISHED_AT DESC LIMIT 1', params=[env]).collect()
        if not rows:
            return None                                              # first logged deployment of this env
        out = subprocess.run(['git', '-C', HERE, 'diff', '--name-only', rows[0][0], 'HEAD', '--', '.'],
                             capture_output=True, text=True, check=True).stdout
        return ', '.join(p.removeprefix('deployment/') for p in out.split()) or 'none'
    except Exception:                                               # no log table yet, no git (Snowsight), commit not fetched
        return None


def write_log(session, cfg, env, **row):
    """One row in APP.T_F_DEPLOY_LOG; a failure to log is printed, never raised (the deployment result stands)."""
    gh = os.environ.get                                              # set by GitHub Actions, absent in Snowsight
    row |= {'ENV': env, 'GIT_COMMIT': gh('GITHUB_SHA'), 'TRIGGERED_BY': gh('GITHUB_ACTOR'),
            'RUN_URL': f"{gh('GITHUB_SERVER_URL')}/{gh('GITHUB_REPOSITORY')}/actions/runs/{gh('GITHUB_RUN_ID')}" if gh('GITHUB_RUN_ID') else None}
    values = ', '.join('COALESCE(?, CURRENT_USER())' if c == 'TRIGGERED_BY' else '?' for c in row)   # Snowsight: the Snowflake user
    try:
        session.sql(f'USE ROLE "{cfg["role_owner"]}"').collect()
        session.sql(f"INSERT INTO {cfg['database']}.APP.T_F_DEPLOY_LOG ({', '.join(row)}) SELECT {values}",
                    params=list(row.values())).collect()               # bound values: quotes in an error message are safe
    except Exception as e:
        print(f'WARNING: deployment log not written: {first_line(e)}')


def deploy_all(env='uat', only=None, run=False, session=None, verify_only=False):
    """Dry run unless run=True. Runs through the Snowpark session (the active one in Snowsight), then verifies and logs."""
    rendered = render_all(env, only)
    if verify_only and not run:
        if not verify(env, session)[0]:
            raise RuntimeError(f'DEPLOYMENT NOT CONFIRMED ({env})')
        return
    if not run:
        for name, sql in rendered.items():
            print(f'\n-- ===== {name} ({env}) =====\n{sql}')
        return
    from snowflake.connector.util_text import split_statements     # keeps $$ bodies whole
    session = session or get_session()
    cfg = load_cfg(env)
    session.sql(f'USE ROLE "{cfg["role_owner"]}"').collect()
    started = session.sql('SELECT CURRENT_TIMESTAMP()::TIMESTAMP_NTZ').collect()[0][0]
    before = show_objects(session, cfg['database'])[0]              # to log what appeared / disappeared
    log = {'STATUS': 'FAILED', 'SCRIPTS_RUN': len(rendered), 'STARTED_AT': started,
           'CHANGED_SCRIPTS': changed_scripts(session, cfg['database'], env)}
    try:
        for name, sql in rendered.items():                          # silent; only a failure or the verification is printed
            for stmt, _ in split_statements(io.StringIO(sql), remove_comments=True):
                stmt = stmt.strip()
                if stmt:
                    try:
                        session.sql(stmt).collect()
                    except Exception as e:                           # stops at the first failure, naming the script
                        log |= {'FAILED_SCRIPT': name, 'ERROR_MESSAGE': first_line(e)}
                        raise RuntimeError(f'DEPLOYMENT FAILED ({env}) in {name}: {first_line(e)}') from None
        confirmed, summary, problems = verify(env, session)         # a finished run is not yet a successful deployment
        log |= {'STATUS': 'CONFIRMED' if confirmed else 'NOT CONFIRMED', 'VERIFY_SUMMARY': summary,
                'ERROR_MESSAGE': problems or None}
        if not confirmed:
            raise RuntimeError(f'DEPLOYMENT NOT CONFIRMED ({env})')
    finally:
        after = show_objects(session, cfg['database'])[0]
        moved = [f'added: {k[:-1]} {n}' for k in SCHEMA for n in sorted(after[k] - before[k])]
        moved += [f'removed: {k[:-1]} {n}' for k in SCHEMA for n in sorted(before[k] - after[k])]
        write_log(session, cfg, env, OBJECTS_ADDED_REMOVED='; '.join(moved) or None, **log)


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('env')
    ap.add_argument('only', nargs='*', help=f"folders ({'/'.join(SCHEMA)}) or script names; default: all")
    ap.add_argument('--run', action='store_true', help='execute, then verify (default: only print)')
    ap.add_argument('-c', '--connection', help='Snowflake connection name (connections.toml)')
    if len(sys.argv) < 2 or sys.argv[1].startswith('-'):     # no terminal arguments (Snowsight): use the settings above
        return deploy_all(ENV, ONLY, RUN, verify_only=VERIFY)
    a = ap.parse_args()
    if not a.run:
        return deploy_all(a.env, a.only or None)
    deploy_all(a.env, a.only or None, run=True, session=get_session(a.connection))


if __name__ == '__main__':
    main()
