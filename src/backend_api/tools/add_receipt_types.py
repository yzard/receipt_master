"""One-time offline addition of parallel receipt types. Never run by service startup."""
import argparse
import sqlite3
from contextlib import closing
from pathlib import Path

from expand_tax_codes import check, fingerprints

UNKNOWN = '10000000-0000-4000-8000-000000000001'
GROCERY = '10000000-0000-4000-8000-000000000002'
SCHEMA = Path(__file__).resolve().parents[1] / 'schema.sql'


def preflight(path: Path) -> bool:
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
        check(db)
        version = db.execute('PRAGMA user_version').fetchone()[0]
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
        if version == 16 and {'receipt_type', 'receipt_type_assignment', 'merchant_receipt_type', 'line_receipt_type_assignment'} <= tables:
            return False
        if version != 15 or 'receipt_type' in tables or not {'receipt', 'receipt_line', 'merchant', 'line_discount'} <= tables:
            raise ValueError(f'{path}: expected version 15 with no receipt-type tables')
        return True


def upgrade(path: Path) -> None:
    schema = SCHEMA.read_text().split('-- BEGIN RECEIPT TYPES\n', 1)[1].split('-- END RECEIPT TYPES', 1)[0]
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=rw', uri=True)) as db:
        db.execute('PRAGMA foreign_keys=ON')
        before = fingerprints(db)
        db.executescript('BEGIN EXCLUSIVE;\n' + schema)
        # The old application supported groceries only. Existing merchant records
        # and receipts retain that context; future unknown merchants stay unclassified.
        db.execute('INSERT INTO merchant_receipt_type SELECT merchant_id,? FROM merchant', (GROCERY,))
        db.execute('INSERT INTO receipt_type_assignment SELECT receipt_id,? FROM receipt', (GROCERY,))
        db.execute('PRAGMA user_version=16')
        check(db)
        after = fingerprints(db)
        if any(after.get(table) != digest for table, digest in before.items()):
            raise ValueError(f'{path}: preexisting table data changed; rolling back')
        db.commit()
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')


def run(data_dir: Path, backup_dir: Path) -> int:
    if not data_dir.is_dir():
        raise ValueError('Data directory does not exist')
    paths = [data_dir / 'database/receipts.sqlite', *sorted(data_dir.glob('users/*/database/receipts.sqlite'))]
    paths = [p for p in paths if p.is_file()]
    if not paths:
        raise ValueError('No receipt databases found')
    pending = [p for p in paths if preflight(p)]
    if not pending:
        print(f'Already updated: {len(paths)} database(s)')
        return 0
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
        upgrade(path)
        print(f'Updated: {path.relative_to(data_dir)} (all preexisting data preserved)')
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
