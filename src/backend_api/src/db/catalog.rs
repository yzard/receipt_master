use super::*;
impl Store {
    pub fn save_product_name(
        &self,
        printed_name_id: &str,
        value: &str,
        category: &str,
    ) -> Result<bool> {
        self.one(
            "SELECT printed_name_id FROM printed_name WHERE printed_name_id=?",
            &[json!(printed_name_id)],
        )?;
        let name = normalized(value);
        let before = self.rows("SELECT n.name FROM printed_name_product_name m JOIN product_name n USING(product_name_id) WHERE m.printed_name_id=?", &[json!(printed_name_id)])?.first().map(|r|r["name"].as_str().unwrap().to_owned()).unwrap_or_default();
        if name.is_empty() {
            self.exec(
                "DELETE FROM printed_name_product_name WHERE printed_name_id=?",
                &[json!(printed_name_id)],
            )?;
        } else {
            self.exec("INSERT INTO product_name VALUES (?,?,?,?) ON CONFLICT(name) DO UPDATE SET last_used_at_utc_ms=excluded.last_used_at_utc_ms", &[json!(id()),json!(name),json!(category),json!(now())])?;
            let row = self.one(
                "SELECT product_name_id FROM product_name WHERE name=?",
                &[json!(name)],
            )?;
            self.exec("INSERT INTO printed_name_product_name VALUES (?,?) ON CONFLICT(printed_name_id) DO UPDATE SET product_name_id=excluded.product_name_id", &[json!(printed_name_id),row["product_name_id"].clone()])?;
        }
        Ok(before != name)
    }

    pub fn prune_unused_product_names(&self) -> Result<()> {
        self.exec("DELETE FROM product_name WHERE NOT EXISTS (SELECT 1 FROM printed_name_product_name m WHERE m.product_name_id=product_name.product_name_id)", &[])?;
        Ok(())
    }

    /// Detach inactive receipts while retaining their proposal, classification and weight.
    /// Then remove catalogue entries unsupported by any active confirmed receipt.
    pub fn reconcile_catalog(&self) -> Result<()> {
        self.exec("INSERT INTO line_product_name_candidate SELECT l.line_id,n.name FROM receipt_line l JOIN receipt r USING(receipt_id) JOIN product p USING(product_id) JOIN printed_name_product_name m USING(printed_name_id) JOIN product_name n USING(product_name_id) WHERE r.status<>'posted' OR r.deleted_at_utc_ms IS NOT NULL ON CONFLICT(line_id) DO NOTHING", &[])?;
        self.exec("UPDATE line_category_assignment SET category_id=(SELECT e.category_id FROM line_effective_category e WHERE e.line_id=line_category_assignment.line_id) WHERE line_id IN (SELECT l.line_id FROM receipt_line l JOIN receipt r USING(receipt_id) WHERE l.product_id IS NOT NULL AND (r.status<>'posted' OR r.deleted_at_utc_ms IS NOT NULL))", &[])?;
        self.exec("INSERT INTO line_unmatched_weight SELECT l.line_id,p.weight_g FROM receipt_line l JOIN receipt r USING(receipt_id) JOIN product p USING(product_id) WHERE p.weight_g IS NOT NULL AND (r.status<>'posted' OR r.deleted_at_utc_ms IS NOT NULL) ON CONFLICT(line_id) DO UPDATE SET weight_g=excluded.weight_g", &[])?;
        self.exec("UPDATE receipt_line SET product_id=NULL WHERE receipt_id IN (SELECT receipt_id FROM receipt WHERE status<>'posted' OR deleted_at_utc_ms IS NOT NULL)", &[])?;
        self.exec("DELETE FROM product WHERE NOT EXISTS (SELECT 1 FROM receipt_line l WHERE l.product_id=product.product_id)", &[])?;
        self.exec("DELETE FROM printed_name WHERE NOT EXISTS (SELECT 1 FROM product p WHERE p.printed_name_id=printed_name.printed_name_id)", &[])?;
        self.prune_unused_product_names()?;
        Ok(())
    }

    pub fn restore_receipt_catalog(&self, receipt: &str) -> Result<()> {
        let lines=self.rows("SELECT l.line_id,l.raw_name,a.category_id,CAST(ROUND(w.weight_g*1000) AS INTEGER) AS weight_mg,c.name FROM receipt_line l JOIN receipt r USING(receipt_id) JOIN line_category_assignment a USING(line_id) LEFT JOIN line_unmatched_weight w USING(line_id) LEFT JOIN line_product_name_candidate c USING(line_id) WHERE l.receipt_id=? AND l.kind='product' AND r.status='posted' AND r.deleted_at_utc_ms IS NULL", &[json!(receipt)])?;
        for line in lines {
            let raw = normalized(text(&line, "raw_name")?);
            if raw.is_empty() {
                continue;
            }
            let printed = self.printed_name(&raw)?;
            let product = self.product(&printed, line["weight_mg"].clone())?;
            if let Some(name) = line["name"].as_str()
                && self
                    .rows(
                        "SELECT 1 FROM printed_name_product_name WHERE printed_name_id=?",
                        &[json!(printed)],
                    )?
                    .is_empty()
            {
                self.save_product_name(&printed, name, text(&line, "category_id")?)?;
            }
            self.exec(
                "UPDATE receipt_line SET product_id=? WHERE line_id=?",
                &[json!(product), line["line_id"].clone()],
            )?;
            self.exec(
                "DELETE FROM line_unmatched_weight WHERE line_id=?",
                &[line["line_id"].clone()],
            )?;
        }
        self.exec("DELETE FROM line_product_name_candidate WHERE line_id IN (SELECT l.line_id FROM receipt_line l JOIN receipt r USING(receipt_id) WHERE l.receipt_id=? AND r.status='posted' AND r.deleted_at_utc_ms IS NULL)", &[json!(receipt)])?;
        Ok(())
    }

    pub fn catalog_action(&self, component: &str, op: &str, v: &Value) -> Result<Value> {
        let write = !matches!(op, "list" | "suggest" | "get");
        if write {
            let version = self.one("SELECT version FROM catalog_version WHERE id=1", &[])?;
            if version["version"] != v["expected_version"] {
                return Err(conflict());
            }
        }
        let result=match (component,op){
 ("config","save_weight_unit")=>{
 let unit=text(v,"weight_unit")?;
 if !["g","kg","lb","oz"].contains(&unit){return Err(invalid());}
 self.exec("UPDATE app_preferences SET weight_unit=? WHERE id=1",&[json!(unit)])?;
 Value::Null},
 ("categories","list")=>json!(self.rows("WITH RECURSIVE tree AS (SELECT category_id,parent_id,name,system_key,name AS path,0 AS depth FROM category WHERE parent_id IS NULL UNION ALL SELECT c.category_id,c.parent_id,c.name,c.system_key,t.path || ' / ' || c.name,t.depth+1 FROM category c JOIN tree t ON c.parent_id=t.category_id) SELECT * FROM tree ORDER BY path",&[])?),
 ("categories","save")=>{let name=normalized(text(v,"name")?);if name.is_empty(){return Err(invalid());}
if v["id"].is_null(){self.exec("INSERT INTO category VALUES (?,?,?,NULL)",&[json!(id()),v["parent"].clone(),json!(name)])?;}else{self.one("SELECT category_id FROM category WHERE category_id=?",&[v["id"].clone()])?;self.exec("UPDATE category SET name=?,parent_id=? WHERE category_id=?",&[json!(name),v["parent"].clone(),v["id"].clone()])?;}Value::Null},
 ("categories","delete")=>{let row=self.one("SELECT * FROM category WHERE category_id=?",&[v["id"].clone()])?;if !row["system_key"].is_null(){return Err(invalid());}
 self.exec("UPDATE category SET parent_id=NULL WHERE parent_id=?",&[v["id"].clone()])?;
 for q in ["UPDATE product_name SET category_id=? WHERE category_id=?","UPDATE line_category_assignment SET category_id=? WHERE category_id=?"]{self.exec(q,&[json!(UNCATEGORIZED),v["id"].clone()])?;}
 self.exec("DELETE FROM category WHERE category_id=?",&[v["id"].clone()])?;Value::Null},
 ("printed_names","list")=>json!(self.rows("SELECT p.*,n.product_name_id,n.name AS product_name FROM printed_name p LEFT JOIN printed_name_product_name m USING(printed_name_id) LEFT JOIN product_name n USING(product_name_id) ORDER BY p.raw_name",&[])?),
 ("printed_names","set_product_name")=>{self.save_product_name(text(v,"id")?,text(v,"name")?,UNCATEGORIZED)?;self.prune_unused_product_names()?;
 self.exec("UPDATE line_category_assignment SET category_id=COALESCE((SELECT n.category_id FROM printed_name_product_name m JOIN product_name n USING(product_name_id) WHERE m.printed_name_id=?),?) WHERE line_id IN (SELECT l.line_id FROM receipt_line l JOIN product p USING(product_id) WHERE p.printed_name_id=?)",&[v["id"].clone(),json!(UNCATEGORIZED),v["id"].clone()])?;
 Value::Null},
 ("product_names","list")=>json!(self.rows("SELECT n.*,c.name AS category_name FROM product_name n JOIN category c USING(category_id) ORDER BY n.last_used_at_utc_ms DESC,n.name",&[])?),
 ("product_names","delete")=>{self.one("SELECT product_name_id FROM product_name WHERE product_name_id=?",&[v["id"].clone()])?;self.exec("DELETE FROM product_name WHERE product_name_id=?",&[v["id"].clone()])?;Value::Null},
 ("product_names","classify")=>{
 self.one("SELECT product_name_id FROM product_name WHERE product_name_id=?",&[v["id"].clone()])?;
 let category=if let Some(category)=v["category_id"].as_str(){self.one("SELECT category_id FROM category WHERE category_id=?",&[json!(category)])?["category_id"].clone()}else{
 let name=normalized(text(v,"category_name")?);if name.is_empty(){return Err(invalid());}
 let rows=self.rows("SELECT category_id FROM category WHERE name=? ORDER BY category_id",&[json!(name)])?;
 if rows.len()>1{return Err(invalid());}
 if let Some(row)=rows.first(){row["category_id"].clone()}else{let key=id();self.exec("INSERT INTO category VALUES (?,NULL,?,NULL)",&[json!(key),json!(name)])?;json!(key)}};
 self.exec("UPDATE product_name SET category_id=? WHERE product_name_id=?",&[category.clone(),v["id"].clone()])?;
 self.exec("UPDATE line_category_assignment SET category_id=? WHERE line_id IN (SELECT l.line_id FROM receipt_line l JOIN product p USING(product_id) JOIN printed_name_product_name m USING(printed_name_id) WHERE m.product_name_id=?)",&[category,v["id"].clone()])?;Value::Null},
 ("products","list")=>json!(self.rows("SELECT p.*,CAST(ROUND(p.weight_g*1000) AS INTEGER) AS weight_mg,n.raw_name,a.name AS product_name,COALESCE(a.category_id,'00000000-0000-4000-8000-000000000001') AS category_id,c.name AS category_name FROM product p JOIN printed_name n USING(printed_name_id) LEFT JOIN printed_name_product_name m USING(printed_name_id) LEFT JOIN product_name a USING(product_name_id) JOIN category c ON c.category_id=COALESCE(a.category_id,'00000000-0000-4000-8000-000000000001') ORDER BY n.raw_name,p.weight_g",&[])?),
 ("products","suggest")=>json!(self.rows("SELECT p.*,CAST(ROUND(p.weight_g*1000) AS INTEGER) AS weight_mg,n.raw_name,COALESCE(a.category_id,'00000000-0000-4000-8000-000000000001') AS category_id FROM product p JOIN printed_name n USING(printed_name_id) LEFT JOIN printed_name_product_name m USING(printed_name_id) LEFT JOIN product_name a USING(product_name_id) WHERE n.raw_name=? ORDER BY p.weight_g",&[json!(normalized(text(v,"name")?))])?),
 _=>return Err(missing())};
        if write {
            self.exec(
                "UPDATE catalog_version SET version=version+1 WHERE id=1",
                &[],
            )?;
            // Catalog changes can change the effective contents of any open receipt editor.
            if component != "config" {
                self.exec(
                    "UPDATE receipt SET version=version+1,updated_at_utc_ms=?",
                    &[json!(now())],
                )?;
            }
        }
        Ok(result)
    }
}
