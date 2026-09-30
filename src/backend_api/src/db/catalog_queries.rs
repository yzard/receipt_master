pub const PRODUCT_NAMES_CONTAINING: &str = "
SELECT n.*, c.name AS category_name
  FROM product_name n JOIN category c USING(category_id)
 WHERE n.name LIKE ?1 ESCAPE '\\'
 ORDER BY n.last_used_at_utc_ms DESC, n.name, n.product_name_id";

pub const PRODUCT_NAME_BY_NAME: &str = "SELECT * FROM product_name WHERE name = ?1 COLLATE NOCASE";
pub const CATEGORY_BY_NAME: &str = "SELECT * FROM category WHERE name = ?1 COLLATE NOCASE";
pub const UPSERT_PRODUCT_NAME: &str = "
INSERT INTO product_name VALUES (?1, ?2, ?3, ?4)
ON CONFLICT(name COLLATE NOCASE)
DO UPDATE SET last_used_at_utc_ms = excluded.last_used_at_utc_ms";

pub const CATEGORIES_CONTAINING: &str = "
WITH RECURSIVE tree AS (
    SELECT category_id, parent_id, name, system_key, name AS path, 0 AS depth
      FROM category WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, c.parent_id, c.name, c.system_key,
           t.path || ' / ' || c.name, t.depth + 1
      FROM category c JOIN tree t ON c.parent_id = t.category_id
)
SELECT * FROM tree
 WHERE name LIKE ?1 ESCAPE '\\' OR path LIKE ?1 ESCAPE '\\'
 ORDER BY path, category_id";
