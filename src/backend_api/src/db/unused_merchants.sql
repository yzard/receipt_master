SELECT m.merchant_id, m.name
  FROM merchant m
 WHERE NOT EXISTS (SELECT 1 FROM logo_sample l WHERE l.merchant_id=m.merchant_id)
   AND NOT EXISTS (
       SELECT 1 FROM store_location s JOIN receipt r USING(location_id)
        WHERE s.merchant_id=m.merchant_id)
   AND NOT EXISTS (
       SELECT 1 FROM sku s JOIN line_sku l USING(sku_id)
        WHERE s.merchant_id=m.merchant_id)
 ORDER BY m.merchant_id
