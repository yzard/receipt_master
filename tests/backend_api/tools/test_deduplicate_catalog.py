import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'src/backend_api/tools'
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location('deduplicate_catalog', TOOLS / 'deduplicate_catalog.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class DeduplicateCatalogTest(unittest.TestCase):
    def create_db(self, path):
        path.parent.mkdir(parents=True)
        schema = (ROOT / 'src/backend_api/schema.sql').read_text()
        for sql in repair.INDEXES.values():
            schema = schema.replace(sql + ';', '')
        with closing(sqlite3.connect(path)) as db:
            db.executescript(schema)
            db.executescript(f'''
                INSERT INTO category VALUES ('{repair.UNCATEGORIZED}',NULL,'未分类','uncategorized');
                INSERT INTO category VALUES ('cat1',NULL,'小麦及其制品',NULL),('cat2',NULL,'小麦及其制品',NULL),('child','cat2','子类',NULL);
                INSERT INTO product_name VALUES ('p1','Bottled Water','cat1',1),('p2','bottled water','cat2',2),('p3','Ｂｏｔｔｌｅｄ　 Ｗａｔｅｒ','{repair.UNCATEGORIZED}',3);
                INSERT INTO printed_name VALUES ('n1','WT1'),('n2','WT2'),('n3','WT3'),('n4','WT4');
                INSERT INTO printed_name_product_name VALUES ('n1','p1'),('n2','p1'),('n3','p2'),('n4','p3');
                INSERT INTO receipt(receipt_id,created_at_utc_ms,updated_at_utc_ms) VALUES ('r',1,1);
                INSERT INTO receipt_line(line_id,receipt_id,position,kind,raw_name) VALUES ('l','r',0,'product','WT1');
                INSERT INTO line_category_assignment VALUES ('l','cat2');
                INSERT INTO line_product_name_candidate VALUES ('l','bottled water');
                INSERT INTO media_blob VALUES ('blob','media/originals/photo.png','hash',100,'image/png',10,10,1);
                INSERT INTO receipt_image VALUES ('image','r',0,'blob','blob',NULL,1,NULL,NULL);
            ''')
            db.commit()

    def test_merges_all_namespaces_preserving_links_photos_and_backup(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'data'
            paths = [root / 'database/receipts.sqlite', root / 'users/u1/database/receipts.sqlite']
            for path in paths:
                self.create_db(path)
            backup = Path(temp) / 'backup'
            self.assertEqual(repair.run(root, backup), 2)
            for path in paths:
                with closing(sqlite3.connect(path)) as db:
                    self.assertEqual(
                        db.execute('SELECT product_name_id,name,last_used_at_utc_ms FROM product_name').fetchall(),
                        [('p1', 'Bottled Water', 3)],
                    )
                    self.assertEqual(
                        db.execute('SELECT DISTINCT product_name_id FROM printed_name_product_name').fetchall(),
                        [('p1',)],
                    )
                    self.assertEqual(
                        db.execute('SELECT name FROM line_product_name_candidate').fetchone()[0], 'Bottled Water'
                    )
                    self.assertEqual(
                        db.execute('SELECT COUNT(*) FROM category WHERE name=?', ('小麦及其制品',)).fetchone()[0], 1
                    )
                    cid = db.execute('SELECT category_id FROM category WHERE name=?', ('小麦及其制品',)).fetchone()[0]
                    self.assertEqual(db.execute('SELECT category_id FROM product_name').fetchone()[0], cid)
                    self.assertEqual(db.execute('SELECT category_id FROM line_category_assignment').fetchone()[0], cid)
                    self.assertEqual(
                        db.execute("SELECT parent_id FROM category WHERE category_id='child'").fetchone()[0], cid
                    )
                    self.assertEqual(db.execute('SELECT original_blob_id FROM receipt_image').fetchone()[0], 'blob')
                    repair.check(db)
                    with self.assertRaises(sqlite3.IntegrityError):
                        db.execute("INSERT INTO product_name VALUES ('new','BOTTLED WATER',?,0)", (cid,))
                    with self.assertRaises(sqlite3.IntegrityError):
                        db.execute("INSERT INTO category VALUES ('new',NULL,'小麦及其制品',NULL)")
                with closing(sqlite3.connect(backup / path.relative_to(root))) as db:
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM product_name').fetchone()[0], 3)
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM receipt').fetchone()[0], 1)
            self.assertEqual(repair.run(root, backup), 0)

    def test_duplicate_parent_and_child_merge_without_self_cycle(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'data/database/receipts.sqlite'
            self.create_db(path)
            with closing(sqlite3.connect(path)) as db, db:
                db.execute("UPDATE category SET parent_id='cat1' WHERE category_id='cat2'")
            repair.run(path.parents[1], Path(temp) / 'backup')
            with closing(sqlite3.connect(path)) as db:
                repair.check(db)
                self.assertEqual(
                    db.execute('SELECT parent_id FROM category WHERE name=?', ('小麦及其制品',)).fetchone()[0], None
                )

    def test_preflight_refuses_conflicting_system_names_before_any_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'data'
            first = root / 'database/receipts.sqlite'
            second = root / 'users/u1/database/receipts.sqlite'
            self.create_db(first)
            self.create_db(second)
            with closing(sqlite3.connect(second)) as db, db:
                db.execute("INSERT INTO category VALUES ('tip',NULL,'未分类','tip')")
            with self.assertRaises(ValueError):
                repair.run(root, Path(temp) / 'backup')
            with closing(sqlite3.connect(first)) as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM product_name').fetchone()[0], 3)
            self.assertFalse((Path(temp) / 'backup').exists())


if __name__ == '__main__':
    unittest.main()
