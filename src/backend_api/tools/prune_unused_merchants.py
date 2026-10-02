"""Offline cleanup of store metadata with no logo, receipt or used SKU. Stop API first."""
import argparse
import sqlite3
from contextlib import closing
from pathlib import Path

from expand_tax_codes import check, fingerprints

QUERIES = Path(__file__).resolve().parents[1] / 'src/db'
UNUSED = (QUERIES / 'unused_merchants.sql').read_text()
# These are the only tables allowed to lose orphaned metadata.
MUTABLE = {'merchant', 'merchant_alias', 'merchant_receipt_type', 'store_location', 'sku', 'catalog_version'}


def cleanup(path: Path) -> list[str]:
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=rw', uri=True)) as db:
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('BEGIN EXCLUSIVE')
        before = fingerprints(db)
        unused = db.execute(UNUSED).fetchall()
        for merchant_id, _ in unused:
            for table in ('sku', 'store_location', 'merchant_alias', 'merchant'):
                db.execute(f'DELETE FROM {table} WHERE merchant_id=?', (merchant_id,))
        if unused:
            db.execute('UPDATE catalog_version SET version=version+1 WHERE id=1')
        check(db)
        after = fingerprints(db)
        if any(after.get(table) != digest for table, digest in before.items() if table not in MUTABLE):
            raise ValueError('Receipt or other protected data changed; rolling back')
        db.commit()
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        return [name for _, name in unused]


def run(data_dir: Path, backup_dir: Path) -> int:
    paths = [data_dir / 'database/receipts.sqlite', *sorted(data_dir.glob('users/*/database/receipts.sqlite'))]
    paths = [p for p in paths if p.is_file()]
    if not paths:
        raise ValueError('No receipt databases found')
    pending = []
    for path in paths:
        with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
            check(db)
            if db.execute(UNUSED).fetchone():
                pending.append(path)
    if not pending:
        print('No orphaned stores')
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
    count = 0
    for path in pending:
        removed = cleanup(path)
        count += len(removed)
        print(f'{path.relative_to(data_dir)}: removed {removed}')
    print(f'Backup: {backup_dir}')
    return count


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--backup-dir', type=Path, required=True)
    args = parser.parse_args()
    run(args.data_dir, args.backup_dir)
