"""One-time offline catalogue repair. Stop backend_api before running; never used at startup."""

import argparse
import sqlite3
import time
import unicodedata
from collections import defaultdict
from contextlib import closing
from pathlib import Path

from expand_tax_codes import check, fingerprints

UNCATEGORIZED = '00000000-0000-4000-8000-000000000001'
ASCII_CASE = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')
INDEXES = {
    'category_name_uq': 'CREATE UNIQUE INDEX category_name_uq ON category(name COLLATE NOCASE)',
    'product_name_name_uq': 'CREATE UNIQUE INDEX product_name_name_uq ON product_name(name COLLATE NOCASE)',
}


def display_name(value: str) -> str:
    return ' '.join(unicodedata.normalize('NFKC', value).split())


def name_key(value: str) -> str:
    return display_name(value).translate(ASCII_CASE)


def plan(db: sqlite3.Connection, table: str):
    db.row_factory = sqlite3.Row
    groups = defaultdict(list)
    for row in db.execute(f'SELECT * FROM {table}'):
        if not display_name(row['name']):
            raise ValueError(f'{table}: empty normalized name')
        groups[name_key(row['name'])].append(dict(row))
    reference_sql = (
        'SELECT (SELECT COUNT(*) FROM product_name WHERE category_id=?) + '
        '(SELECT COUNT(*) FROM line_category_assignment WHERE category_id=?)'
        if table == 'category'
        else 'SELECT COUNT(*) FROM printed_name_product_name WHERE product_name_id=?'
    )
    key = f'{table}_id'
    result = []
    for rows in groups.values():
        if table == 'category' and sum(row['system_key'] is not None for row in rows) > 1:
            raise ValueError('Two protected system categories have the same name; resolve manually')
        for row in rows:
            args = (row[key], row[key]) if table == 'category' else (row[key],)
            row['references'] = db.execute(reference_sql, args).fetchone()[0]
        rows.sort(
            key=lambda row: (
                0 if table == 'category' and row['system_key'] is not None else 1,
                -row['references'],
                row[key],
            )
        )
        result.append((rows[0], rows[1:]))
    return result


def pending(path: Path) -> bool:
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as db:
        check(db)
        changed = any(
            losers or keeper['name'] != display_name(keeper['name'])
            for table in ('category', 'product_name')
            for keeper, losers in plan(db, table)
        )
        db.row_factory = None
        existing = {row[0] for row in db.execute("SELECT name FROM sqlite_schema WHERE type='index'")}
        return changed or not INDEXES.keys() <= existing


def repair(path: Path) -> dict:
    with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=rw', uri=True)) as db:
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('BEGIN EXCLUSIVE')
        before = fingerprints(db)
        category_plan = plan(db, 'category')
        product_plan = plan(db, 'product_name')
        db.row_factory = None
        category_map = {
            row['category_id']: keeper['category_id'] for keeper, losers in category_plan for row in [keeper, *losers]
        }
        counts = {'category': 0, 'product_name': 0}
        canonical_names = {}
        for keeper, losers in product_plan:
            canonical = display_name(keeper['name'])
            for row in [keeper, *losers]:
                canonical_names[name_key(row['name'])] = canonical
            # Prefer an existing explicit classification to uncategorized.
            category = next(
                (
                    category_map[row['category_id']]
                    for row in [keeper, *losers]
                    if category_map[row['category_id']] != UNCATEGORIZED
                ),
                UNCATEGORIZED,
            )
            for row in losers:
                db.execute(
                    'UPDATE printed_name_product_name SET product_name_id=? WHERE product_name_id=?',
                    (keeper['product_name_id'], row['product_name_id']),
                )
                db.execute('DELETE FROM product_name WHERE product_name_id=?', (row['product_name_id'],))
                print(f"Merge product_name {row['product_name_id']} -> {keeper['product_name_id']}: {row['name']}")
                counts['product_name'] += 1
            db.execute(
                'UPDATE product_name SET name=?,category_id=?,last_used_at_utc_ms=? WHERE product_name_id=?',
                (
                    canonical,
                    category,
                    max(row['last_used_at_utc_ms'] for row in [keeper, *losers]),
                    keeper['product_name_id'],
                ),
            )
        # Detach parent links while merging to avoid transient/self cycles.
        parents = db.execute('SELECT category_id,parent_id FROM category').fetchall()
        db.execute('UPDATE category SET parent_id=NULL')
        for keeper, losers in category_plan:
            for row in losers:
                for table in ('product_name', 'line_category_assignment'):
                    db.execute(
                        f'UPDATE {table} SET category_id=? WHERE category_id=?',
                        (keeper['category_id'], row['category_id']),
                    )
                db.execute('DELETE FROM category WHERE category_id=?', (row['category_id'],))
                print(f"Merge category {row['category_id']} -> {keeper['category_id']}: {row['name']}")
                counts['category'] += 1
            db.execute(
                'UPDATE category SET name=? WHERE category_id=?', (display_name(keeper['name']), keeper['category_id'])
            )
        # Keep the chosen category's parent; absorb duplicate ancestors into it.
        old_parents = dict(parents)
        for keeper, _ in category_plan:
            cid = keeper['category_id']
            parent = old_parents[cid]
            seen = {cid}
            while parent is not None and category_map[parent] == cid:
                if parent in seen:
                    raise ValueError('Category cycle in merge')
                seen.add(parent)
                parent = old_parents[parent]
            db.execute(
                'UPDATE category SET parent_id=? WHERE category_id=?',
                (category_map[parent] if parent is not None else None, cid),
            )
        for line_id, name in db.execute('SELECT line_id,name FROM line_product_name_candidate').fetchall():
            canonical = canonical_names.get(name_key(name), display_name(name))
            if name != canonical:
                db.execute('UPDATE line_product_name_candidate SET name=? WHERE line_id=?', (canonical, line_id))
        for index, sql in INDEXES.items():
            if not db.execute('SELECT 1 FROM sqlite_schema WHERE name=?', (index,)).fetchone():
                db.execute(sql)
        check(db)
        after = fingerprints(db)
        changed_tables = {
            'category',
            'product_name',
            'printed_name_product_name',
            'line_category_assignment',
            'line_product_name_candidate',
        }
        if any(after[table] != digest for table, digest in before.items() if table not in changed_tables):
            raise ValueError('Unrelated receipt/photo data changed; rolling back')
        if before != after:
            db.execute('UPDATE catalog_version SET version=version+1 WHERE id=1')
            db.execute('UPDATE receipt SET version=version+1,updated_at_utc_ms=?', (int(time.time() * 1000),))
        db.commit()
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        return counts


def run(data_dir: Path, backup_dir: Path) -> int:
    paths = [data_dir / 'database/receipts.sqlite', *sorted(data_dir.glob('users/*/database/receipts.sqlite'))]
    paths = [path for path in paths if path.is_file()]
    if not paths:
        raise ValueError('No receipt databases found')
    todo = [path for path in paths if pending(path)]
    if not todo:
        print(f'Already updated: {len(paths)} database(s)')
        return 0
    backup_dir.mkdir(parents=True, exist_ok=False, mode=0o700)
    for path in todo:
        target = backup_dir / path.relative_to(data_dir)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with closing(sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)) as source:
            with closing(sqlite3.connect(target)) as dest:
                source.backup(dest)
                check(dest)
        target.chmod(0o600)
    for path in todo:
        print(f'Updated {path.relative_to(data_dir)}: {repair(path)}')
    print(f'Backup: {backup_dir}')
    return len(todo)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', required=True, type=Path)
    parser.add_argument('--backup-dir', required=True, type=Path)
    args = parser.parse_args()
    run(args.data_dir, args.backup_dir)


if __name__ == '__main__':
    main()
