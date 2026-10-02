import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'src/backend_api/tools'))
spec = importlib.util.spec_from_file_location('add_receipt_types', ROOT / 'src/backend_api/tools/add_receipt_types.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class AddReceiptTypesTest(unittest.TestCase):
    def create_db(self, path):
        path.parent.mkdir(parents=True)
        schema = (ROOT / 'src/backend_api/schema.sql').read_text()
        block = schema.split('-- BEGIN RECEIPT TYPES\n', 1)[1].split('-- END RECEIPT TYPES', 1)[0]
        schema = schema.replace(block, '').replace('PRAGMA user_version=16;', 'PRAGMA user_version=15;')
        with closing(sqlite3.connect(path)) as db:
            db.executescript(schema)
            db.executescript("""
                INSERT INTO merchant VALUES ('costco','Costco');
                INSERT INTO receipt(receipt_id,raw_store,created_at_utc_ms,updated_at_utc_ms) VALUES ('r','Costco',1,1);
                INSERT INTO receipt_line(line_id,receipt_id,position,kind,raw_name,amount_minor) VALUES ('l','r',0,'product','MILK',100);
                INSERT INTO media_blob VALUES ('blob','media/originals/photo.png','hash',100,'image/png',10,10,1);
                INSERT INTO receipt_image VALUES ('image','r',0,'blob','blob',NULL,1,NULL,NULL);
            """)
            db.commit()

    def test_upgrades_all_namespaces_preserves_records_and_is_repeatable(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'data'
            paths = [root / 'database/receipts.sqlite', root / 'users/u1/database/receipts.sqlite']
            for path in paths:
                self.create_db(path)
            backup = Path(temp) / 'backup'
            self.assertEqual(repair.run(root, backup), 2)
            for path in paths:
                with closing(sqlite3.connect(path)) as db:
                    self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 16)
                    self.assertEqual(db.execute('SELECT receipt_type_id FROM line_effective_receipt_type').fetchone()[0], repair.GROCERY)
                    self.assertEqual(db.execute('SELECT receipt_type_id FROM merchant_receipt_type').fetchone()[0], repair.GROCERY)
                    self.assertEqual(db.execute('SELECT original_blob_id FROM receipt_image').fetchone()[0], 'blob')
                    repair.check(db)
                with closing(sqlite3.connect(backup / path.relative_to(root))) as old, closing(sqlite3.connect(path)) as new:
                    before = repair.fingerprints(old)
                    after = repair.fingerprints(new)
                    self.assertTrue(all(after[key] == value for key, value in before.items()))
            self.assertEqual(repair.run(root, backup), 0)

    def test_preflight_refuses_partial_and_unsupported_schemas_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'data'
            first = root / 'database/receipts.sqlite'
            bad = root / 'users/u1/database/receipts.sqlite'
            self.create_db(first)
            self.create_db(bad)
            with closing(sqlite3.connect(bad)) as db:
                db.execute('PRAGMA user_version=14')
            with self.assertRaises(ValueError):
                repair.run(root, Path(temp) / 'backup')
            self.assertTrue(repair.preflight(first))
            self.assertFalse((Path(temp) / 'backup').exists())


if __name__ == '__main__':
    unittest.main()
