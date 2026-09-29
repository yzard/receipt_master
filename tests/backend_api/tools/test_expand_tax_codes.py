import importlib.util
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[3] / 'src/backend_api/tools/expand_tax_codes.py'
spec = importlib.util.spec_from_file_location('expand_tax_codes', SCRIPT)
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class ExpandTaxCodesTest(unittest.TestCase):
    def create_db(self, path):
        path.parent.mkdir(parents=True)
        with closing(sqlite3.connect(path)) as db, db:
            db.executescript('''
                PRAGMA foreign_keys=ON;
                PRAGMA user_version=15;
                CREATE TABLE receipt_line(line_id TEXT PRIMARY KEY);
                CREATE TABLE line_tax_code (
                    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
                    tax_code TEXT NOT NULL CHECK (length(tax_code) = 1)
                );
                CREATE INDEX tax_idx ON line_tax_code(tax_code);
                CREATE TABLE untouched(value BLOB);
                INSERT INTO untouched VALUES (X'00FF');
                INSERT INTO receipt_line VALUES ('old'),('new');
                INSERT INTO line_tax_code VALUES ('old','E');
            ''')

    def test_updates_all_namespaces_preserves_data_and_backup_and_is_repeatable(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'data'
            paths = [root / 'database/receipts.sqlite', root / 'users/u1/database/receipts.sqlite']
            for path in paths:
                self.create_db(path)
            backup = Path(temp) / 'backup'
            self.assertEqual(repair.run(root, backup), 2)
            for path in paths:
                with closing(sqlite3.connect(path)) as db, db:
                    db.execute('PRAGMA foreign_keys=ON')
                    self.assertEqual(db.execute('SELECT * FROM line_tax_code').fetchall(), [('old', 'E')])
                    db.execute("INSERT INTO line_tax_code VALUES ('new','ABC')")
                    for code in ['', 'ABCD']:
                        with self.assertRaises(sqlite3.IntegrityError):
                            db.execute("UPDATE line_tax_code SET tax_code=? WHERE line_id='new'", (code,))
                    db.execute('PRAGMA foreign_keys=ON')
                    self.assertTrue(db.execute("SELECT name FROM sqlite_schema WHERE name='tax_idx'").fetchone())
                    self.assertEqual(db.execute('SELECT * FROM untouched').fetchall(), [(b'\x00\xff',)])
                    db.execute("DELETE FROM receipt_line WHERE line_id='new'")
                    self.assertEqual(db.execute('SELECT * FROM line_tax_code').fetchall(), [('old', 'E')])
                with closing(sqlite3.connect(backup / path.relative_to(root))) as old, old:
                    with self.assertRaises(sqlite3.IntegrityError):
                        old.execute("INSERT INTO line_tax_code VALUES ('new','ABC')")
            self.assertEqual(repair.run(root, backup), 0)

    def test_preflight_failure_does_not_modify_any_database(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'data'
            first = root / 'database/receipts.sqlite'
            invalid = root / 'users/u1/database/receipts.sqlite'
            self.create_db(first)
            self.create_db(invalid)
            with closing(sqlite3.connect(invalid)) as db, db:
                db.execute('DROP TABLE line_tax_code')
            with self.assertRaises(ValueError):
                repair.run(root, Path(temp) / 'backup')
            self.assertTrue(repair.preflight(first))
            self.assertFalse((Path(temp) / 'backup').exists())


if __name__ == '__main__':
    unittest.main()
