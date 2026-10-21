"""Render the setup scripts (`{{ key }}` placeholders + config.yml) and run them in order or one by one.

In Snowsight (Workspace with this folder uploaded): set ENV / FILES / RUN below, press Run on this file.
RUN = False only prints the SQL; RUN = True executes it. Or call it from a notebook cell:
    exec(open('deploy.py').read())                       # or: from deploy import deploy_all
    deploy_all('dev')                                    # dry run: print all rendered scripts
    deploy_all('dev', files=['05_grants.sql'])           # dry run: one script ("05" also works)
    deploy_all('dev', files=['05'], run=True)            # run one script
    deploy_all('dev', run=True)                          # run 01..06 in order, stop on the first error

From a terminal (needs: pip install pyyaml):
    python deploy.py dev 05                              # print one script (nothing runs)
    python deploy.py dev 05 --run -c myconn              # run it with the Snowflake CLI (`snow`)

Everything is rendered before anything runs; a missing config key stops the run.
"""
import os
import re
import sys
import tempfile

import yaml

# Snowsight: set these, then press Run on this file. (A terminal call like `python deploy.py dev 05` ignores them.)
ENV = 'dev'                           # a block in config.yml
FILES = None                          # None = all of DEPLOY_ORDER, or e.g. ['05']
RUN = False                           # False = print the SQL only; True = execute it

# This folder (a notebook has no __file__: use the working directory)
HERE = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else os.getcwd()

DEPLOY_ORDER = [                      # a new script is added here; run order = list order
    '01_environments.sql',

]


def render(text, cfg):
    """Replace every {{ key }} with cfg[key]."""
    def sub(m):
        if m.group(1) not in cfg:
            raise KeyError(f"Config key '{m.group(1)}' not found. Available: {sorted(cfg)}")
        return str(cfg[m.group(1)])
    return re.sub(r'\{\{\s*(\w+)\s*\}\}', sub, text)


def render_all(env, selectors=None):
    """{file name: rendered SQL} for the selected scripts (default: all of DEPLOY_ORDER)."""
    with open(os.path.join(HERE, 'config.yml'), encoding='utf-8') as f:
        cfg = yaml.safe_load(f)
    if env not in cfg:
        raise KeyError(f'No environment {env!r} in config.yml (has: {", ".join(cfg)})')
    names = []
    for s in selectors or DEPLOY_ORDER:
        hits = [n for n in DEPLOY_ORDER if n == s or n.startswith(s)]
        if len(hits) != 1:
            raise ValueError(f'{s!r} matches {hits or "nothing"}; DEPLOY_ORDER: {", ".join(DEPLOY_ORDER)}')
        names.append(hits[0])
    out = {}
    for n in names:
        with open(os.path.join(HERE, n), encoding='utf-8') as f:
            out[n] = render(f.read(), cfg[env])
    return out


def deploy_all(env='dev', files=None, run=True, session=None):
    """Dry run unless run=True. Runs through the Snowpark session (the active one in Snowsight)."""
    rendered = render_all(env, files)           # render everything before running anything
    if not run:
        for name, sql in rendered.items():
            print(f'\n-- ===== {name} ({env}) =====\n{sql}')
        return
    from snowflake.connector.util_text import split_statements     # keeps $$ bodies whole
    if session is None:
        from snowflake.snowpark.context import get_active_session
        session = get_active_session()
    import io
    for name, sql in rendered.items():
        print(f'\n{name} ({env})')
        for stmt, _ in split_statements(io.StringIO(sql), remove_comments=True):
            stmt = stmt.strip()
            if stmt:
                print(f"  {' '.join(stmt.split())[:80]} ...")
                print(f'    -> {session.sql(stmt).collect()[:1]}')   # raises and stops on failure


def main():
    import argparse
    import shutil
    import subprocess
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('env')
    ap.add_argument('files', nargs='*')
    ap.add_argument('--run', action='store_true', help='execute with the Snowflake CLI (default: only print)')
    ap.add_argument('-c', '--connection', help='Snowflake CLI connection name')
    if len(sys.argv) < 2 or sys.argv[1].startswith('-'):    # no terminal arguments (Snowsight): use the settings above
        return deploy_all(ENV, FILES, RUN)
    a = ap.parse_args()
    if not a.run:
        return deploy_all(a.env, a.files)
    rendered = render_all(a.env, a.files)
    snow = shutil.which('snow') or sys.exit('Snowflake CLI (`snow`) not found on PATH')
    with tempfile.TemporaryDirectory() as tmp:
        for name, sql in rendered.items():
            path = os.path.join(tmp, name)
            with open(path, 'w', encoding='utf-8') as f:
                f.write(sql)
            print(f'\n>>> {name} ({a.env})', flush=True)
            cmd = [snow, 'sql', '-f', path] + (['-c', a.connection] if a.connection else [])
            subprocess.run(cmd, check=True)


if __name__ == '__main__':
    main()
