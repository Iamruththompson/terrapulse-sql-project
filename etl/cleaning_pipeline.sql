-- ============================================================================
-- TERRAPULSE_DW — ETL CLEANING PIPELINE (Phase 2: Ingestion + Phase 3: Cleaning)
-- Target: MySQL 8.0+
-- Run schema/terrapulse_ddl.sql first to create the database and tables.
-- ============================================================================

USE terrapulse_dw;

-- PHASE 2: INGESTION & STAGING
-- ============================================================================

-- 2.1 Load raw files via MySQL Workbench "Table Data Import Wizard"
--     (right-click each stg_* table -> Table Data Import Wizard -> select
--     matching CSV/TSV). For the two JSON sources (customers, fx_rates),
--     either pre-convert to CSV in Python/pandas, or load with JSON_TABLE():
--
-- Example JSON_TABLE pattern for stg_fx_rates if loaded as a single JSON doc
-- into a temp column first:
--
-- INSERT INTO stg_fx_rates (currency_code, currency_name, rate_to_usd)
-- SELECT jt.currency_code, jt.currency_name, jt.rate_to_usd
-- FROM raw_fx_json_import rj,
-- JSON_TABLE(rj.json_col, '$[*]' COLUMNS (
--     currency_code VARCHAR(10) PATH '$.currency_code',
--     currency_name VARCHAR(100) PATH '$.currency_name',
--     rate_to_usd   VARCHAR(50)  PATH '$.rate_to_usd'
-- )) AS jt;

-- 2.2 Ingestion count verification
SELECT 'stg_fx_rates' AS source_table, COUNT(*) AS row_count FROM stg_fx_rates
UNION ALL
SELECT 'stg_products', COUNT(*) FROM stg_products
UNION ALL
SELECT 'stg_customers', COUNT(*) FROM stg_customers
UNION ALL
SELECT 'stg_orders', COUNT(*) FROM stg_orders
UNION ALL
SELECT 'stg_logistics', COUNT(*) FROM stg_logistics;

-- 2.3 Data quality audit — count dirty records before cleaning
SELECT
    (SELECT COUNT(*) FROM stg_customers WHERE TRIM(IFNULL(raw_phone,''))    = '') AS missing_phones,
    (SELECT COUNT(*) FROM stg_customers WHERE TRIM(IFNULL(raw_email,''))    = '') AS missing_emails,
    (SELECT COUNT(*) FROM stg_customers WHERE TRIM(IFNULL(raw_loyalty_score,'')) = '') AS missing_loyalty,
    (SELECT COUNT(*) FROM stg_logistics WHERE TRIM(IFNULL(raw_ship_date,'')) = '') AS missing_ship_dates,
    (SELECT COUNT(*) FROM stg_orders
        WHERE raw_order_date NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        AND raw_order_date NOT REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
        AND raw_order_date NOT REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
    ) AS orders_nonstandard_dates,
    (SELECT COUNT(DISTINCT UPPER(TRIM(raw_status))) FROM stg_orders) AS distinct_status_variants;


-- ============================================================================
-- PHASE 3: ETL CLEANING PIPELINE
-- ============================================================================

-- 3.1 Currencies, categories, products -----------------------------------

INSERT INTO dim_currencies (currency_code, currency_name, rate_to_usd)
SELECT DISTINCT
    TRIM(currency_code),
    TRIM(currency_name),
    CAST(TRIM(rate_to_usd) AS DECIMAL(15,6))
FROM stg_fx_rates;

INSERT INTO dim_categories (category_name)
SELECT DISTINCT TRIM(raw_category_name)
FROM stg_products
WHERE TRIM(IFNULL(raw_category_name,'')) <> '';

INSERT INTO dim_products (product_id, sku_code, product_name, category_id,
                            unit_cost_usd, retail_price_usd, warehouse_stock)
SELECT
    CAST(sp.product_id AS UNSIGNED),
    TRIM(sp.sku_code),
    TRIM(sp.product_name),
    dc.category_id,
    CAST(sp.unit_cost_usd AS DECIMAL(15,2)),
    CAST(sp.retail_price_usd AS DECIMAL(15,2)),
    CAST(sp.warehouse_stock AS UNSIGNED)
FROM stg_products sp
JOIN dim_categories dc ON dc.category_name = TRIM(sp.raw_category_name);

-- 3.2 Customer standardization --------------------------------------------

INSERT INTO dim_customers (customer_id, first_name, last_name, full_name,
                            email, phone_clean, country, city,
                            loyalty_score, registration_date)
SELECT
    CAST(sc.customer_id AS UNSIGNED),
    CONCAT(UPPER(LEFT(TRIM(sc.raw_first_name),1)), LOWER(SUBSTRING(TRIM(sc.raw_first_name),2))) AS first_name,
    CONCAT(UPPER(LEFT(TRIM(sc.raw_last_name),1)),  LOWER(SUBSTRING(TRIM(sc.raw_last_name),2)))  AS last_name,
    CONCAT_WS(' ',
        CONCAT(UPPER(LEFT(TRIM(sc.raw_first_name),1)), LOWER(SUBSTRING(TRIM(sc.raw_first_name),2))),
        CONCAT(UPPER(LEFT(TRIM(sc.raw_last_name),1)),  LOWER(SUBSTRING(TRIM(sc.raw_last_name),2)))
    ) AS full_name,
    LOWER(TRIM(sc.raw_email)) AS email,
    TRIM(sc.raw_phone) AS phone_clean,
    TRIM(sc.country) AS country,
    TRIM(sc.city) AS city,
    CAST(COALESCE(NULLIF(TRIM(sc.raw_loyalty_score), ''), '500') AS UNSIGNED) AS loyalty_score,
    CASE
        WHEN TRIM(sc.raw_registration_date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            THEN STR_TO_DATE(TRIM(sc.raw_registration_date), '%Y-%m-%d')
        WHEN TRIM(sc.raw_registration_date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            THEN STR_TO_DATE(TRIM(sc.raw_registration_date), '%m/%d/%Y')
        WHEN TRIM(sc.raw_registration_date) REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
            THEN STR_TO_DATE(TRIM(sc.raw_registration_date), '%d-%b-%Y')
        WHEN TRIM(sc.raw_registration_date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            THEN STR_TO_DATE(TRIM(sc.raw_registration_date), '%d/%m/%Y')
        ELSE NULL
    END AS registration_date
FROM stg_customers sc;

-- 3.3 Order status standardization + multi-currency conversion ------------

INSERT INTO fct_orders (order_id, customer_id, product_id, currency_code,
                          order_date, order_status, quantity,
                          unit_price_native, unit_price_usd, gross_amount_usd,
                          discount_pct, discount_amount_usd, shipping_fee_usd,
                          net_revenue_usd)
SELECT
    CAST(so.order_id AS UNSIGNED),
    CAST(so.customer_id AS UNSIGNED),
    CAST(so.product_id AS UNSIGNED),
    TRIM(so.currency_code),
    CASE
        WHEN TRIM(so.raw_order_date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            THEN STR_TO_DATE(TRIM(so.raw_order_date), '%Y-%m-%d')
        WHEN TRIM(so.raw_order_date) REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
            THEN STR_TO_DATE(TRIM(so.raw_order_date), '%d-%b-%Y')
        -- Ambiguous DD/MM vs MM/DD slash formats: treat as MM/DD/YYYY per
        -- brief's documented format list; adjust here if your source uses
        -- the other convention.
        WHEN TRIM(so.raw_order_date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            THEN STR_TO_DATE(TRIM(so.raw_order_date), '%m/%d/%Y')
        ELSE NULL
    END AS order_date,
    CONCAT(UPPER(LEFT(TRIM(so.raw_status),1)), LOWER(SUBSTRING(TRIM(so.raw_status),2))) AS order_status,
    CAST(so.quantity AS UNSIGNED),
    CAST(so.unit_price_native AS DECIMAL(15,2)),
    ROUND(CAST(so.unit_price_native AS DECIMAL(15,2)) * fx.rate_to_usd, 2) AS unit_price_usd,
    ROUND(CAST(so.unit_price_native AS DECIMAL(15,2)) * fx.rate_to_usd * CAST(so.quantity AS UNSIGNED), 2) AS gross_amount_usd,
    CAST(so.discount_pct AS DECIMAL(5,2)),
    ROUND(CAST(so.unit_price_native AS DECIMAL(15,2)) * fx.rate_to_usd * CAST(so.quantity AS UNSIGNED)
          * (CAST(so.discount_pct AS DECIMAL(5,2)) / 100), 2) AS discount_amount_usd,
    CAST(so.shipping_fee_usd AS DECIMAL(15,2)),
    ROUND(
        (CAST(so.unit_price_native AS DECIMAL(15,2)) * fx.rate_to_usd * CAST(so.quantity AS UNSIGNED))
        - (CAST(so.unit_price_native AS DECIMAL(15,2)) * fx.rate_to_usd * CAST(so.quantity AS UNSIGNED)
              * (CAST(so.discount_pct AS DECIMAL(5,2)) / 100))
        + CAST(so.shipping_fee_usd AS DECIMAL(15,2)), 2
    ) AS net_revenue_usd
FROM stg_orders so
JOIN dim_currencies fx ON fx.currency_code = TRIM(so.currency_code);

-- 3.4 Logistics cleaning ----------------------------------------------------

INSERT INTO fct_logistics (order_id, carrier_name, tracking_number,
                             ship_date, shipping_lead_days, warehouse_origin)
SELECT
    CAST(sl.order_id AS UNSIGNED),
    CASE
        WHEN TRIM(IFNULL(sl.raw_carrier_name,'')) = '' THEN 'Unassigned'
        ELSE CONCAT(UPPER(LEFT(TRIM(sl.raw_carrier_name),1)), LOWER(SUBSTRING(TRIM(sl.raw_carrier_name),2)))
    END AS carrier_name,
    TRIM(sl.tracking_number),
    ship_dt.ship_date,
    DATEDIFF(ship_dt.ship_date, fo.order_date) AS shipping_lead_days,
    TRIM(sl.warehouse_origin)
FROM stg_logistics sl
JOIN fct_orders fo ON fo.order_id = CAST(sl.order_id AS UNSIGNED)
CROSS JOIN LATERAL (
    SELECT CASE
        WHEN TRIM(sl.raw_ship_date) REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            THEN STR_TO_DATE(TRIM(sl.raw_ship_date), '%Y-%m-%d')
        WHEN TRIM(sl.raw_ship_date) REGEXP '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
            THEN STR_TO_DATE(TRIM(sl.raw_ship_date), '%d-%b-%Y')
        WHEN TRIM(sl.raw_ship_date) REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            THEN STR_TO_DATE(TRIM(sl.raw_ship_date), '%m/%d/%Y')
        ELSE NULL
    END AS ship_date
) AS ship_dt;


-- ============================================================================
