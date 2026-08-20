"""Create and manage login credentials.

There is no self-service signup: an operator creates every account. Run locally
against a tunnelled database, or as a one-off ECS task in AWS (see the
`deploy-aws` skill, "Create the first login" section).

    python -m app.cli.manage_users create --email you@example.com --name "Your Name" --role admin
    python -m app.cli.manage_users set-password --email you@example.com
    python -m app.cli.manage_users disable --email someone@example.com
    python -m app.cli.manage_users list

Passwords are read from the AOLF_NEW_PASSWORD environment variable when set,
otherwise prompted for without echo. Never pass a password as a CLI argument --
it lands in shell history and in `ps` output.
"""

from __future__ import annotations

import argparse
import getpass
import os
import sys

from app.auth.passwords import WeakPasswordError
from app.auth.roles import KNOWN_ROLES
from app.auth.users import create_user, list_users, set_active, set_password
from app.db.session import db_connection


def _read_password(confirm: bool = True) -> str:
    from_env = os.environ.get("AOLF_NEW_PASSWORD")
    if from_env:
        return from_env
    if not sys.stdin.isatty():
        raise SystemExit("No TTY available. Set AOLF_NEW_PASSWORD instead.")
    password = getpass.getpass("New password: ")
    if confirm and password != getpass.getpass("Confirm password: "):
        raise SystemExit("Passwords did not match.")
    return password


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="manage_users", description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create", help="Create a user, or reset an existing one.")
    create.add_argument("--email", required=True)
    create.add_argument("--name", required=True)
    create.add_argument(
        "--role",
        action="append",
        default=None,
        help=f"Repeatable. One of: {', '.join(sorted(KNOWN_ROLES))}. Defaults to staff.",
    )

    reset = subparsers.add_parser("set-password", help="Replace a user's password.")
    reset.add_argument("--email", required=True)

    disable = subparsers.add_parser("disable", help="Block sign-in without deleting the account.")
    disable.add_argument("--email", required=True)

    enable = subparsers.add_parser("enable", help="Re-allow sign-in for a disabled account.")
    enable.add_argument("--email", required=True)

    subparsers.add_parser("list", help="Show every account.")

    args = parser.parse_args(argv)

    try:
        with db_connection() as conn:
            if args.command == "create":
                user = create_user(
                    conn,
                    email=args.email,
                    display_name=args.name,
                    password=_read_password(),
                    roles=args.role,
                )
                print(f"Created {user.email} with roles: {', '.join(user.roles)}")
            elif args.command == "set-password":
                set_password(conn, args.email, _read_password())
                print(f"Password updated for {args.email}")
            elif args.command == "disable":
                set_active(conn, args.email, False)
                print(f"Disabled {args.email}")
            elif args.command == "enable":
                set_active(conn, args.email, True)
                print(f"Enabled {args.email}")
            elif args.command == "list":
                for row in list_users(conn):
                    state = "active" if row["is_active"] else "disabled"
                    roles = ", ".join(row["roles"]) or "-"
                    print(f"{row['email']:<40} {state:<9} {roles:<20} last login: {row['last_login_at'] or 'never'}")
    except (WeakPasswordError, LookupError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
