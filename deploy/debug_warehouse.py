"""Debug 'USE WAREHOUSE ... failed: 002043' (temporary): what can this Snowflake user really use?

    python deploy/debug_warehouse.py uat             # GitHub Actions: SNOWFLAKE_* environment variables
    python deploy/debug_warehouse.py uat -c myconn   # terminal: named connection

Read-only (USE and SHOW only). For every role the user has it tries USE ROLE, USE DATABASE and USE WAREHOUSE for each
warehouse that role can see, compares that with deploy/config.yml, and prints the cause and the fix.
Exit code 0 = config.yml works as it is, 1 = it does not.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy


def attempt(session, stmt):
    """None when the statement works, else the error on one line."""
    try:
        session.sql(stmt).collect()
    except Exception as e:
        return deploy.first_line(e)


def diagnose(session, cfg):
    user, login_role, roles, account = session.sql(
        'SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_AVAILABLE_ROLES(), CURRENT_ACCOUNT()').collect()[0]
    roles = sorted(json.loads(roles))
    want_role, want_db, want_wh = cfg['role_owner'], cfg['database'], cfg['warehouse']
    print(f'account {account} | user {user} | login role {login_role}')
    print(f'config.yml: role {want_role} | database {want_db} | warehouse {want_wh}')
    print(f'roles of this user: {", ".join(roles)}\n')

    info = {}                                           # role -> (USE DATABASE error or None, warehouses it sees, warehouses it can USE)
    for r in roles:
        err = attempt(session, f'USE ROLE "{r}"')
        if err:
            print(f'  {r:<32} USE ROLE failed: {err}')
            continue
        db_err = attempt(session, f'USE DATABASE {want_db}')
        try:
            visible = sorted(str(w['name']) for w in session.sql('SHOW WAREHOUSES').collect())
        except Exception as e:
            visible = []
            print(f'  {r:<32} SHOW WAREHOUSES failed: {deploy.first_line(e)}')
        usable = [w for w in visible if attempt(session, f'USE WAREHOUSE "{w}"') is None]
        info[r] = (db_err, visible, usable)
        print(f'  {r:<32} database: {"OK" if not db_err else "NO"} | warehouses it can USE: {", ".join(usable) or "none"}')

    print()
    db_err, visible, usable = info.get(want_role, (None, [], []))
    if want_role not in info:
        print(f'CAUSE: the user cannot use role {want_role}.\n'
              f'  Fix: GRANT ROLE "{want_role}" TO USER {user};   (or change role_owner in config.yml)')
    elif want_wh in usable and not db_err:
        print(f'OK: {want_role} can use database {want_db} and warehouse {want_wh}. config.yml is fine; run the deploy again.')
        return True
    else:
        if db_err:
            print(f'CAUSE: {want_role} cannot USE DATABASE {want_db}: {db_err}\n'
                  f'  Fix: GRANT USAGE ON DATABASE {want_db} TO ROLE "{want_role}";   (or the database name is wrong)')
        if want_wh not in usable:
            seen_by_some_role = {w for _, v, _ in info.values() for w in v}
            if want_wh in seen_by_some_role:
                print(f'CAUSE: warehouse {want_wh} exists but {want_role} cannot use it.\n'
                      f'  Fix: GRANT USAGE ON WAREHOUSE {want_wh} TO ROLE "{want_role}";')
            else:
                print(f'CAUSE: no role of this user can see a warehouse named {want_wh}: it does not exist (check the name) '
                      f'or the user has no privilege on it.\n'
                      f'  Warehouses visible to this user: {", ".join(sorted(seen_by_some_role)) or "none"}')

    options = [f'set warehouse: {w}' for w in usable if w != want_wh] if not db_err and want_role in info else []
    if options:
        print(f'  Option: keep role {want_role}; {" / ".join(options)} in deploy/config.yml and in both SNOWFLAKE_WAREHOUSE lines of '
              f'.github/workflows/eurocham-deploy.yml')
    works = [f'{r} + {w}' for r, (d, _, u) in info.items() if r != want_role and not d for w in u]
    if works:
        print(f'  Option: roles that can already reach {want_db} and a warehouse: {"; ".join(works)}\n'
              f'          (role_owner owns the objects deploy.py creates: pick the role that should own them)')
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('env', nargs='?', default='uat')
    ap.add_argument('-c', '--connection', help='connection name from the Snowflake CLI config (not needed in GitHub Actions)')
    a = ap.parse_args()
    os.environ.pop('SNOWFLAKE_WAREHOUSE', None)         # a wrong value must not break the login we need for looking around
    sys.exit(0 if diagnose(deploy.get_session(a.connection), deploy.load_cfg(a.env)) else 1)


if __name__ == '__main__':
    main()
