PRAGMA foreign_keys = ON;

CREATE TABLE currency (
    code TEXT PRIMARY KEY,
    minor_digits INTEGER NOT NULL CHECK (minor_digits BETWEEN 0 AND 6)
);

CREATE TABLE merchant (
    merchant_id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK (length(trim(name)) > 0)
);

CREATE TABLE store_location (
    location_id TEXT PRIMARY KEY,
    merchant_id TEXT NOT NULL REFERENCES merchant(merchant_id),
    branch_name TEXT,
    address TEXT,
    country_code TEXT CHECK (country_code IS NULL OR length(country_code) = 2)
);

CREATE TABLE category (
    category_id TEXT PRIMARY KEY,
    parent_id TEXT REFERENCES category(category_id),
    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
    system_key TEXT UNIQUE CHECK (
        system_key IS NULL OR system_key IN (
            'uncategorized', 'tax', 'tip', 'deposit', 'order_discount'
        )
    ),
    CHECK (parent_id IS NULL OR parent_id <> category_id)
);

CREATE TABLE printed_name (
    printed_name_id TEXT PRIMARY KEY,
    raw_name TEXT NOT NULL UNIQUE CHECK (length(trim(raw_name)) > 0)
);

CREATE TABLE product_name (
    product_name_id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE CHECK (length(trim(name)) > 0),
    category_id TEXT NOT NULL REFERENCES category(category_id),
    last_used_at_utc_ms INTEGER NOT NULL
);
CREATE INDEX product_name_category_idx ON product_name(category_id);

CREATE TABLE printed_name_product_name (
    printed_name_id TEXT PRIMARY KEY REFERENCES printed_name(printed_name_id) ON DELETE CASCADE,
    product_name_id TEXT NOT NULL REFERENCES product_name(product_name_id) ON DELETE CASCADE
);
CREATE INDEX printed_name_product_name_idx ON printed_name_product_name(product_name_id);

CREATE TABLE product (
    product_id TEXT PRIMARY KEY,
    printed_name_id TEXT NOT NULL REFERENCES printed_name(printed_name_id),
    weight_g INTEGER CHECK (weight_g IS NULL OR weight_g > 0)
);
CREATE UNIQUE INDEX product_known_weight_uq
    ON product(printed_name_id, weight_g) WHERE weight_g IS NOT NULL;
CREATE UNIQUE INDEX product_unknown_weight_uq
    ON product(printed_name_id) WHERE weight_g IS NULL;



CREATE TABLE receipt (
    receipt_id TEXT PRIMARY KEY,
    location_id TEXT REFERENCES store_location(location_id),
    currency_code TEXT REFERENCES currency(code),
    country_code TEXT CHECK (country_code IS NULL OR length(country_code) = 2),
    raw_store TEXT,
    raw_branch TEXT,
    raw_address TEXT,
    raw_time_text TEXT,
    occurred_at_utc_ms INTEGER,
    time_source TEXT NOT NULL DEFAULT 'unresolved' CHECK (
        time_source IN ('unresolved', 'recognized', 'user_entered',
                        'estimated_clock', 'estimated_instant')
    ),
    total_minor INTEGER,
    total_source TEXT CHECK (
        total_source IN ('recognized', 'user_entered', 'user_computed')
    ),
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'posted')),
    version INTEGER NOT NULL DEFAULT 0,
    input_revision INTEGER NOT NULL DEFAULT 0 CHECK (input_revision >= 0),
    created_at_utc_ms INTEGER NOT NULL,
    updated_at_utc_ms INTEGER NOT NULL,
    deleted_at_utc_ms INTEGER,
    CHECK (status = 'draft' OR (
        currency_code IS NOT NULL AND occurred_at_utc_ms IS NOT NULL
        AND total_minor IS NOT NULL AND total_source IS NOT NULL
        AND time_source <> 'unresolved'
    ))
);

CREATE TABLE receipt_line (
    line_id TEXT PRIMARY KEY,
    receipt_id TEXT NOT NULL REFERENCES receipt(receipt_id) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position >= 0),
    kind TEXT NOT NULL CHECK (
        kind IN ('product', 'item_discount', 'order_discount',
                 'tax', 'tip', 'deposit', 'other_adjustment')
    ),
    raw_name TEXT,
    product_id TEXT REFERENCES product(product_id),
    quantity_micros INTEGER CHECK (quantity_micros IS NULL OR quantity_micros > 0),
    quantity_unit TEXT,
    unit_price_scaled INTEGER,
    amount_minor INTEGER,
    CHECK ((quantity_micros IS NULL) = (quantity_unit IS NULL)),
    CHECK (product_id IS NULL OR kind = 'product'),
    CHECK (kind NOT IN ('item_discount', 'order_discount')
           OR amount_minor IS NULL OR amount_minor <= 0),
    CHECK (kind NOT IN ('item_discount', 'order_discount')
           OR unit_price_scaled IS NULL OR unit_price_scaled <= 0),
    UNIQUE (receipt_id, position)
);

-- Receipt-local proposal; drafts and trash never establish global name mappings.
CREATE TABLE line_product_name_candidate (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    name TEXT NOT NULL
);

CREATE TABLE line_category_assignment (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    category_id TEXT NOT NULL REFERENCES category(category_id)
);

CREATE TABLE line_discount (
    discount_line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    target_line_id TEXT NOT NULL REFERENCES receipt_line(line_id),
    CHECK (discount_line_id <> target_line_id)
);

CREATE TABLE media_blob (
    blob_id TEXT PRIMARY KEY,
    relative_path TEXT NOT NULL UNIQUE,
    content_sha256 TEXT NOT NULL,
    byte_length INTEGER NOT NULL CHECK(byte_length>0),
    mime TEXT NOT NULL,
    width_px INTEGER NOT NULL CHECK(width_px>0),
    height_px INTEGER NOT NULL CHECK(height_px>0),
    created_at_utc_ms INTEGER NOT NULL
);
CREATE TABLE receipt_image (
    image_id TEXT PRIMARY KEY,
    receipt_id TEXT NOT NULL REFERENCES receipt(receipt_id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    original_blob_id TEXT NOT NULL REFERENCES media_blob(blob_id),
    current_blob_id TEXT NOT NULL REFERENCES media_blob(blob_id),
    captured_at_utc_ms INTEGER,
    imported_at_utc_ms INTEGER NOT NULL,
    quality_warning TEXT,
    deleted_at_utc_ms INTEGER,
    UNIQUE(receipt_id,position)
);
CREATE TABLE image_revision (
    revision_id TEXT PRIMARY KEY,
    image_id TEXT NOT NULL REFERENCES receipt_image(image_id) ON DELETE CASCADE,
    blob_id TEXT NOT NULL REFERENCES media_blob(blob_id),
    quarter_turns INTEGER NOT NULL,
    created_at_utc_ms INTEGER NOT NULL
);

CREATE TABLE line_image_evidence (
    evidence_id TEXT PRIMARY KEY,
    line_id TEXT NOT NULL REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    image_id TEXT NOT NULL REFERENCES receipt_image(image_id) ON DELETE CASCADE,
    x0 REAL NOT NULL CHECK (x0 BETWEEN 0 AND 1),
    y0 REAL NOT NULL CHECK (y0 BETWEEN 0 AND 1),
    x1 REAL NOT NULL CHECK (x1 BETWEEN 0 AND 1),
    y1 REAL NOT NULL CHECK (y1 BETWEEN 0 AND 1),
    CHECK (x1 > x0 AND y1 > y0)
);

CREATE TABLE recognition_run (
    run_id TEXT PRIMARY KEY,
    receipt_id TEXT NOT NULL REFERENCES receipt(receipt_id) ON DELETE CASCADE,
    input_revision INTEGER NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    provider_request_id TEXT,
    status TEXT NOT NULL CHECK (
        status IN ('queued', 'running', 'succeeded', 'failed', 'unknown', 'cancelled')
    ),
    started_at_utc_ms INTEGER NOT NULL,
    finished_at_utc_ms INTEGER,
    result_relative_path TEXT,
    error_code TEXT,
    estimated_cost_minor INTEGER CHECK (estimated_cost_minor IS NULL OR estimated_cost_minor >= 0),
    cost_currency_code TEXT REFERENCES currency(code),
    CHECK ((estimated_cost_minor IS NULL) = (cost_currency_code IS NULL))
);

CREATE TABLE review_issue (
    issue_id TEXT PRIMARY KEY,
    receipt_id TEXT NOT NULL REFERENCES receipt(receipt_id) ON DELETE CASCADE,
    line_id TEXT REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    field_key TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    confidence REAL CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
    state TEXT NOT NULL CHECK (state IN ('open', 'accepted', 'resolved')),
    created_at_utc_ms INTEGER NOT NULL,
    resolved_at_utc_ms INTEGER
);

CREATE TABLE recognition_budget (
    budget_id TEXT PRIMARY KEY,
    currency_code TEXT NOT NULL REFERENCES currency(code),
    monthly_amount_minor INTEGER NOT NULL CHECK (monthly_amount_minor > 0),
    reminder_percent INTEGER NOT NULL CHECK (reminder_percent BETWEEN 1 AND 100),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1))
);

CREATE INDEX store_location_merchant_idx ON store_location(merchant_id);
CREATE INDEX category_parent_idx ON category(parent_id);


CREATE INDEX receipt_location_idx ON receipt(location_id);
CREATE INDEX receipt_report_idx ON receipt(currency_code, occurred_at_utc_ms)
    WHERE status = 'posted' AND deleted_at_utc_ms IS NULL;
CREATE INDEX line_product_idx ON receipt_line(product_id);
CREATE INDEX assignment_category_idx ON line_category_assignment(category_id);
CREATE INDEX discount_target_idx ON line_discount(target_line_id);
CREATE INDEX image_hash_idx ON media_blob(content_sha256);
CREATE INDEX evidence_line_idx ON line_image_evidence(line_id);
CREATE INDEX evidence_image_idx ON line_image_evidence(image_id);
CREATE INDEX recognition_receipt_idx ON recognition_run(receipt_id);
CREATE INDEX review_receipt_idx ON review_issue(receipt_id, state);
CREATE INDEX review_line_idx ON review_issue(line_id);

CREATE VIEW line_effective_category AS
WITH assigned AS (
    SELECT a.line_id
         , COALESCE(n.category_id, a.category_id) AS category_id
      FROM line_category_assignment AS a
      JOIN receipt_line AS l ON l.line_id = a.line_id
      LEFT JOIN product AS p ON p.product_id = l.product_id
      LEFT JOIN printed_name_product_name AS m ON m.printed_name_id = p.printed_name_id
      LEFT JOIN product_name AS n ON n.product_name_id = m.product_name_id
)
SELECT line_id, category_id FROM assigned
UNION ALL
SELECT d.discount_line_id AS line_id
     , a.category_id
  FROM line_discount AS d
  JOIN assigned AS a ON a.line_id = d.target_line_id;

CREATE VIEW receipt_reconciliation AS
SELECT r.receipt_id
     , r.total_minor
     , COALESCE(SUM(l.amount_minor), 0) AS known_lines_minor
     , SUM(CASE WHEN l.line_id IS NOT NULL AND l.amount_minor IS NULL
                THEN 1 ELSE 0 END) AS missing_amount_count
     , r.total_minor - COALESCE(SUM(l.amount_minor), 0) AS difference_minor
  FROM receipt AS r
  LEFT JOIN receipt_line AS l ON l.receipt_id = r.receipt_id
 GROUP BY r.receipt_id;

CREATE TRIGGER category_cycle_insert BEFORE INSERT ON category
WHEN NEW.parent_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'category cycle') WHERE NEW.category_id IN (
        WITH RECURSIVE ancestors(id) AS (
            SELECT NEW.parent_id
            UNION SELECT c.parent_id FROM category c JOIN ancestors a ON c.category_id=a.id
        ) SELECT id FROM ancestors
    );
END;
CREATE TRIGGER category_cycle_update BEFORE UPDATE OF parent_id ON category
WHEN NEW.parent_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'category cycle') WHERE NEW.category_id IN (
        WITH RECURSIVE ancestors(id) AS (
            SELECT NEW.parent_id
            UNION SELECT c.parent_id FROM category c JOIN ancestors a ON c.category_id=a.id
        ) SELECT id FROM ancestors
    );
END;
CREATE TRIGGER protect_system_category_delete BEFORE DELETE ON category
WHEN OLD.system_key IS NOT NULL
BEGIN SELECT RAISE(ABORT, 'protected category'); END;
CREATE TRIGGER protect_system_category_identity BEFORE UPDATE OF system_key,category_id ON category
WHEN OLD.system_key IS NOT NULL AND (NEW.system_key IS NOT OLD.system_key OR NEW.category_id<>OLD.category_id)
BEGIN SELECT RAISE(ABORT, 'protected category identity'); END;
CREATE TRIGGER discount_scope_insert BEFORE INSERT ON line_discount
BEGIN
    SELECT RAISE(ABORT, 'invalid discount relationship') WHERE NOT EXISTS (
        SELECT 1 FROM receipt_line d JOIN receipt_line t ON d.receipt_id=t.receipt_id
        WHERE d.line_id=NEW.discount_line_id AND t.line_id=NEW.target_line_id
          AND d.kind='item_discount' AND t.kind='product'
    );
END;
CREATE TRIGGER discount_scope_update BEFORE UPDATE ON line_discount
BEGIN
    SELECT RAISE(ABORT, 'invalid discount relationship') WHERE NOT EXISTS (
        SELECT 1 FROM receipt_line d JOIN receipt_line t ON d.receipt_id=t.receipt_id
        WHERE d.line_id=NEW.discount_line_id AND t.line_id=NEW.target_line_id
          AND d.kind='item_discount' AND t.kind='product'
    );
END;
CREATE TRIGGER evidence_scope_insert BEFORE INSERT ON line_image_evidence
BEGIN
    SELECT RAISE(ABORT, 'invalid evidence relationship') WHERE NOT EXISTS (
        SELECT 1 FROM receipt_line l JOIN receipt_image i ON l.receipt_id=i.receipt_id
        WHERE l.line_id=NEW.line_id AND i.image_id=NEW.image_id
    );
END;

-- Receipt-local weight for drafts, trash, or products without a catalogue identity.
-- Matched products use product.weight_g, with no duplicated specification here.
CREATE TABLE line_unmatched_weight (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    weight_g INTEGER NOT NULL CHECK (weight_g > 0)
);

CREATE TABLE catalog_version (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL);
INSERT INTO catalog_version VALUES(1,0);
CREATE TABLE idempotency_record (
    request_key TEXT PRIMARY KEY,
    request_hash TEXT NOT NULL,
    response_json TEXT NOT NULL,
    created_at_utc_ms INTEGER NOT NULL
);
CREATE TABLE recognition_job (
    job_id TEXT PRIMARY KEY,
    receipt_id TEXT NOT NULL REFERENCES receipt(receipt_id) ON DELETE CASCADE,
    receipt_version INTEGER NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('queued','running','succeeded','failed','unknown','cancelled','applied')),
    created_at_utc_ms INTEGER NOT NULL,
    finished_at_utc_ms INTEGER,
    result_json TEXT,
    error_code TEXT
);
CREATE TABLE job_image (
    job_id TEXT NOT NULL REFERENCES recognition_job(job_id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    revision_id TEXT NOT NULL REFERENCES image_revision(revision_id),
    PRIMARY KEY(job_id,position)
);

CREATE TABLE recognition_pricing (
    id INTEGER PRIMARY KEY CHECK(id=1),
    input_rate_micros INTEGER CHECK(input_rate_micros IS NULL OR input_rate_micros>=0),
    output_rate_micros INTEGER CHECK(output_rate_micros IS NULL OR output_rate_micros>=0),
    CHECK((input_rate_micros IS NULL)=(output_rate_micros IS NULL))
);
INSERT INTO recognition_pricing VALUES (1,NULL,NULL);

CREATE TABLE app_preferences (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    weight_unit TEXT NOT NULL CHECK (weight_unit IN ('g', 'kg', 'lb', 'oz'))
);
INSERT INTO app_preferences VALUES (1, 'kg');


CREATE TABLE merchant_alias (
    alias_key TEXT PRIMARY KEY CHECK (length(trim(alias_key)) > 0),
    merchant_id TEXT NOT NULL REFERENCES merchant(merchant_id)
);
CREATE TABLE receipt_ocr_store (
    receipt_id TEXT PRIMARY KEY REFERENCES receipt(receipt_id) ON DELETE CASCADE,
    raw_name TEXT NOT NULL CHECK (length(trim(raw_name)) > 0)
);


CREATE TABLE line_weighed (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE
);


CREATE TABLE line_printed_amount (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    amount_minor INTEGER NOT NULL
);


CREATE TABLE logo_sample (
    logo_id TEXT PRIMARY KEY,
    blob_id TEXT NOT NULL REFERENCES media_blob(blob_id),
    merchant_id TEXT REFERENCES merchant(merchant_id),
    created_at_utc_ms INTEGER NOT NULL
);
CREATE TABLE receipt_logo (
    image_id TEXT PRIMARY KEY REFERENCES receipt_image(image_id) ON DELETE CASCADE,
    source_blob_id TEXT NOT NULL REFERENCES media_blob(blob_id),
    logo_id TEXT NOT NULL REFERENCES logo_sample(logo_id),
    box_json TEXT NOT NULL,
    detection TEXT NOT NULL
);
CREATE INDEX logo_sample_merchant ON logo_sample(merchant_id);


-- SKU codes identify an item within one merchant; names remain in merchant.
CREATE TABLE sku (
    sku_id TEXT PRIMARY KEY,
    merchant_id TEXT NOT NULL REFERENCES merchant(merchant_id),
    code TEXT NOT NULL CHECK (length(trim(code)) > 0),
    UNIQUE (merchant_id, code)
);
CREATE TABLE line_sku (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    sku_id TEXT NOT NULL REFERENCES sku(sku_id)
);
CREATE TABLE line_unmatched_sku (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    code TEXT NOT NULL CHECK (length(trim(code)) > 0)
);
CREATE TABLE line_tax_code (
    line_id TEXT PRIMARY KEY REFERENCES receipt_line(line_id) ON DELETE CASCADE,
    tax_code TEXT NOT NULL CHECK (length(tax_code) = 1)
);
CREATE INDEX line_sku_sku_idx ON line_sku(sku_id);

PRAGMA user_version=15;
