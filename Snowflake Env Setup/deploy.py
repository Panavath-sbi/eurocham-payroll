"""Render the setup scripts (Jinja + config.yml) and optionally run them with the Snowflake CLI.

    python deploy.py dev                          # print all rendered scripts (nothing runs)
    python deploy.py dev 05_grants.sql            # print one script (a prefix like 05 also works)
    python deploy.py dev 05 --run -c myconn       # run it: `snow sql -c myconn -f <rendered file>`
    python deploy.py dev --run -c myconn          # run 01..06 in order, stop on the first failure

Needs: pip install pyyaml jinja2. Running needs the Snowflake CLI (`snow`) and a connection that can
use the roles each script names (SYSADMIN, USERADMIN, SECURITYADMIN, ACCOUNTADMIN).
Everything is rendered before anything runs; a missing config key stops the run.
"""
import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

import jinja2
import yaml

HERE = pathlib.Path(__file__).resolve().parent


def render_all(env, names):
    cfg = yaml.safe_load((HERE / 'config.yml').read_text(encoding='utf-8'))
    if env not in cfg:
        sys.exit(f'No environment {env!r} in config.yml (has: {", ".join(cfg)})')
    jenv = jinja2.Environment(undefined=jinja2.StrictUndefined, trim_blocks=True, lstrip_blocks=True,
                              keep_trailing_newline=True)
    return {n: jenv.from_string((HERE / n).read_text(encoding='utf-8')).render(**cfg[env]) for n in names}


def pick(selectors):
    all_files = sorted(p.name for p in HERE.glob('0*.sql'))
    if not selectors:
        return all_files
    out = []
    for s in selectors:
        hits = [f for f in all_files if f == s or f.startswith(s)]
        if len(hits) != 1:
            sys.exit(f'{s!r} matches {hits or "nothing"}; files: {", ".join(all_files)}')
        out.append(hits[0])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('env')
    ap.add_argument('files', nargs='*')
    ap.add_argument('--run', action='store_true', help='execute with `snow sql` (default: only print)')
    ap.add_argument('-c', '--connection', help='Snowflake CLI connection name')
    a = ap.parse_args()

    rendered = render_all(a.env, pick(a.files))
    if not a.run:
        for name, sql in rendered.items():
            print(f'-- ===== {name} ({a.env}) =====\n{sql}')
        return

    snow = shutil.which('snow') or sys.exit('Snowflake CLI (`snow`) not found on PATH')
    with tempfile.TemporaryDirectory() as tmp:
        for name, sql in rendered.items():
            path = pathlib.Path(tmp) / name
            path.write_text(sql, encoding='utf-8')
            print(f'\n>>> {name} ({a.env})', flush=True)
            cmd = [snow, 'sql', '-f', str(path)] + (['-c', a.connection] if a.connection else [])
            subprocess.run(cmd, check=True)     # raises and stops on failure


if __name__ == '__main__':
    main()
