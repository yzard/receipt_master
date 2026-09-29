"""One-time offline repair for receipt tax codes; never run by service startup."""

import argparse
import hashlib
import sqlite3
from contextlib import closing
from pathlib import Path

OLD_CHECK = "CHECK (length(tax_code) = 1)"
NEW_CHECK = "CHECK (length(tax_code) BETWEEN 1 AND 3)"
CREATE_EXPANDED = """
CREATE TABLE line_tax_code_expanded (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    tax_code TEXT NOT NULL CHECK (length(tax_code) BETWEEN 1 AND 3)
)
"""


def quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def fingerprints(db: sqlite3.Connection) -> dict[str, str]:
    result = {}
    for (name,) in db.execute("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"):
        rows = sorted(repr(row).encode() for row in db.execute(f"SELECT * FROM {quote(name)}"))
        digest = hashlib.sha256()
        for row in rows:
            digest.update(len(row).to_bytes(8, 'big'))
            digest.update(row)
        result[name] = digest.hexdigest()
    return result


def check(db: sqlite3.Connection) -> None:
    if db.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
        raise ValueError('Database integrity check failed')
    if db.execute('PRAGMA foreign_key_check').fetchall():
        raise ValueError('Database has invalid foreign keys')


def preflight(path: Path) -> bool:
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
        check(db)
        row = db.execute("SELECT sql FROM sqlite_schema WHERE type='table' AND name='line_tax_code'").fetchone()
        if row is None:
            raise ValueError(f'{path}: line_tax_code is missing')
        if NEW_CHECK in row[0]:
            return False
        if OLD_CHECK not in row[0]:
            raise ValueError(f'{path}: unexpected tax code constraint')
        for (table,) in db.execute("SELECT name FROM sqlite_schema WHERE type='table'"):
            if any(fk[2] == 'line_tax_code' for fk in db.execute(f'PRAGMA foreign_key_list({quote(table)})')):
                raise ValueError(f'{path}: another table references line_tax_code')
        return True


def expand(path: Path) -> None:
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=rw', uri=True)) as db:
        db.execute('PRAGMA foreign_keys=OFF')
        db.execute('BEGIN EXCLUSIVE')
        before = fingerprints(db)
        version = db.execute('PRAGMA user_version').fetchone()
        objects = db.execute(
            "SELECT sql FROM sqlite_schema WHERE tbl_name='line_tax_code' AND type IN ('index','trigger') AND sql IS NOT NULL"
        ).fetchall()
        db.execute(CREATE_EXPANDED)
        db.execute('INSERT INTO line_tax_code_expanded SELECT line_id,tax_code FROM line_tax_code')
        db.execute('DROP TABLE line_tax_code')
        db.execute('ALTER TABLE line_tax_code_expanded RENAME TO line_tax_code')
        for (sql,) in objects:
            db.execute(sql)
        check(db)
        if fingerprints(db) != before or db.execute('PRAGMA user_version').fetchone() != version:
            raise ValueError(f'{path}: logical data changed; rolling back')
        db.commit()
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')


def run(data_dir: Path, backup_dir: Path) -> int:
    if not data_dir.is_dir():
        raise ValueError('Data directory does not exist')
    paths = [data_dir / 'database' / 'receipts.sqlite']
    paths.extend(sorted(data_dir.glob('users/*/database/receipts.sqlite')))
    paths = [path for path in paths if path.is_file()]
    if not paths:
        raise ValueError('No receipt databases found')
    pending = [path for path in paths if preflight(path)]
    if not pending:
        print(f'Already updated: {len(paths)} database(s)')
        return 0
    # Back up every affected namespace before altering any of them.
    backup_dir.mkdir(parents=True, exist_ok=False, mode=0o700)
    for path in pending:
        destination = backup_dir / path.relative_to(data_dir)
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as source:
            with closing(sqlite3.connect(destination)) as target:
                source.backup(target)
                check(target)
        destination.chmod(0o600)
    for path in pending:
        expand(path)
        print(f'Updated: {path.relative_to(data_dir)} (all table data preserved)')
    print(f'Backup: {backup_dir}')
    return len(pending)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, epilog='Stop backend_api before running this script.')
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--backup-dir', type=Path, required=True)
    args = parser.parse_args()
    run(args.data_dir, args.backup_dir)


if __name__ == '__main__':
    main()
