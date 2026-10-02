import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'src/backend_api/tools'))
spec = importlib.util.spec_from_file_location('prune_unused_merchants', ROOT / 'src/backend_api/tools/prune_unused_merchants.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class PruneUnusedMerchantsTest(unittest.TestCase):
    def test_cleanup_all_namespaces_preserves_receipts_logos_and_used_skus(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'data'
            paths = [root / 'database/receipts.sqlite', root / 'users/u1/database/receipts.sqlite']
            for path in paths:
                path.parent.mkdir(parents=True)
                with closing(sqlite3.connect(path)) as db:
                    db.executescript((ROOT / 'src/backend_api/schema.sql').read_text())
                    db.executescript("""
                        INSERT INTO merchant VALUES ('bad','nice n n n'),('manual','Manual store'),('logo','Costco'),('sku','SKU owner');
                        INSERT INTO store_location VALUES ('location','manual','','','US'),('orphan-location','bad','','','US');
                        INSERT INTO receipt(receipt_id,raw_store,location_id,created_at_utc_ms,updated_at_utc_ms) VALUES ('r','Manual store','location',1,1);
                        INSERT INTO receipt_line(line_id,receipt_id,position,kind,raw_name,amount_minor) VALUES ('l','r',0,'product','MILK',100);
                        INSERT INTO media_blob VALUES ('blob','media/originals/photo.png','hash',100,'image/png',10,10,1);
                        INSERT INTO receipt_image VALUES ('image','r',0,'blob','blob',NULL,1,NULL,NULL);
                        INSERT INTO logo_sample VALUES ('logo','blob','logo',1);
                        INSERT INTO sku VALUES ('unused','bad','123'),('used','sku','456');
                        INSERT INTO line_sku VALUES ('l','used');
                        INSERT INTO merchant_alias VALUES ('garbage','bad');
                        INSERT INTO merchant_receipt_type VALUES ('bad','10000000-0000-4000-8000-000000000002');
                    """)
                    db.commit()
            backup = Path(temp) / 'backup'
            self.assertEqual(repair.run(root, backup), 2)
            for path in paths:
                with closing(sqlite3.connect(backup / path.relative_to(root))) as old, closing(sqlite3.connect(path)) as new:
                    self.assertEqual(new.execute('SELECT merchant_id FROM merchant ORDER BY merchant_id').fetchall(), [('logo',),('manual',),('sku',)])
                    self.assertEqual(new.execute('SELECT sku_id FROM sku').fetchall(), [('used',)])
                    self.assertEqual(new.execute('SELECT * FROM merchant_alias').fetchall(), [])
                    self.assertEqual(new.execute('SELECT * FROM merchant_receipt_type').fetchall(), [])
                    before, after = repair.fingerprints(old), repair.fingerprints(new)
                    self.assertTrue(all(after[key] == value for key, value in before.items() if key not in repair.MUTABLE))
                    repair.check(new)
            self.assertEqual(repair.run(root, backup), 0)


if __name__ == '__main__':
    unittest.main()
