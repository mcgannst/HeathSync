"""Account commands, run inside the server container. Creating the first admin account:

    docker exec -it healthsync-test python -m app.cli create-user stephen --name Stephen --admin

Everyone else can then be added from the Accounts screen in the iOS app.
"""

import argparse
import asyncio
import getpass
import re
import sys

from sqlalchemy import text

from app.config import get_settings
from app.db import Database
from app.security import MIN_PASSWORD_LENGTH, hash_password

USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9._-]{2,50}$")


async def create_user(username: str, display_name: str, is_admin: bool, password: str) -> int:
    db = Database(get_settings())
    try:
        async with db.write() as conn:
            taken = (
                await conn.execute(
                    text("SELECT 1 FROM users WHERE lower(username) = lower(:username)"), {"username": username}
                )
            ).first()
            if taken:
                print(f"The username {username} is already taken.", file=sys.stderr)
                return 1
            await conn.execute(
                text(
                    """
                    INSERT INTO users (username, display_name, password_hash, is_admin)
                    VALUES (:username, :display_name, :password_hash, :is_admin)
                    """
                ),
                {
                    "username": username,
                    "display_name": display_name,
                    "password_hash": hash_password(password),
                    "is_admin": is_admin,
                },
            )
    finally:
        await db.dispose()
    print(f"Created {'admin ' if is_admin else ''}account {username}.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create-user", help="Create an account")
    create.add_argument("username")
    create.add_argument("--name", required=True, help="Display name")
    create.add_argument("--admin", action="store_true", help="Can manage accounts from the iOS app")
    args = parser.parse_args(argv)

    if not USERNAME_PATTERN.fullmatch(args.username):
        print("Usernames are 2-50 letters, numbers, dots, dashes or underscores.", file=sys.stderr)
        return 2
    password = getpass.getpass("Password: ")
    if len(password) < MIN_PASSWORD_LENGTH:
        print(f"Passwords need at least {MIN_PASSWORD_LENGTH} characters.", file=sys.stderr)
        return 2
    if getpass.getpass("Repeat password: ") != password:
        print("The passwords don't match.", file=sys.stderr)
        return 2
    return asyncio.run(create_user(args.username, args.name, args.admin, password))


if __name__ == "__main__":
    sys.exit(main())
