-- ============================================================================
-- TERRAPULSE_DW — FULL DDL (Phase 1: Architecture + Phase 6: Reporting Views)
-- Target: MySQL 8.0+
-- Run this file first to build the empty warehouse; run cleaning_pipeline.sql
-- next to populate it, then business_queries.sql for analysis.
-- ============================================================================

-- PHASE 1: DATABASE ARCHITECTURE (DDL)
-- ============================================================================

-- 1.1 Fresh database
DROP DATABASE IF EXISTS terrapulse_dw;
CREATE DATABASE terrapulse_dw CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE terrapulse_dw;

-- 1.2 Staging layer — everything VARCHAR so raw loads never fail on type

CREATE TABLE stg_orders (
    order_id            VARCHAR(50),
    customer_id         VARCHAR(50),
    product_id          VARCHAR(50),
    raw_order_date       VARCHAR(50),
    raw_status           VARCHAR(50),
    quantity            VARCHAR(50),
    unit_price_native    VARCHAR(50),
    currency_code        VARCHAR(50),
    discount_pct         VARCHAR(50),
    shipping_fee_usd      VARCHAR(50)
);

CREATE TABLE stg_logistics (
    order_id             VARCHAR(50),
    raw_carrier_name       VARCHAR(255),
    tracking_number       VARCHAR(100),
    raw_ship_date          VARCHAR(50),
    warehouse_origin      VARCHAR(100)
);

CREATE TABLE stg_customers (
    customer_id           VARCHAR(50),
    raw_first_name         VARCHAR(255),
    raw_last_name          VARCHAR(255),
    raw_email               VARCHAR(255),
    raw_phone               VARCHAR(100),
    country                VARCHAR(100),
    city                   VARCHAR(100),
    raw_loyalty_score       VARCHAR(50),
    raw_registration_date   VARCHAR(50)
);

CREATE TABLE stg_products (
    product_id            VARCHAR(50),
    sku_code              VARCHAR(50),
    product_name          VARCHAR(255),
    raw_category_name      VARCHAR(100),
    unit_cost_usd          VARCHAR(50),
    retail_price_usd       VARCHAR(50),
    warehouse_stock        VARCHAR(50)
);

CREATE TABLE stg_fx_rates (
    currency_code   VARCHAR(10),
    currency_name   VARCHAR(100),
    rate_to_usd     VARCHAR(50)
);

-- 1.3 Production layer — fully typed, PK/FK enforced, DECIMAL(15,2) money

CREATE TABLE dim_currencies (
    currency_code   CHAR(3)         PRIMARY KEY,
    currency_name   VARCHAR(100)    NOT NULL,
    rate_to_usd     DECIMAL(15,6)   NOT NULL DEFAULT 1.000000
);

CREATE TABLE dim_categories (
    category_id     INT AUTO_INCREMENT PRIMARY KEY,
    category_name   VARCHAR(100)    NOT NULL UNIQUE
);

CREATE TABLE dim_products (
    product_id          INT             PRIMARY KEY,
    sku_code            VARCHAR(50)     NOT NULL,
    product_name        VARCHAR(255)    NOT NULL,
    category_id         INT             NOT NULL,
    unit_cost_usd        DECIMAL(15,2)   NOT NULL DEFAULT 0.00,
    retail_price_usd      DECIMAL(15,2)   NOT NULL DEFAULT 0.00,
    warehouse_stock      INT             NOT NULL DEFAULT 0,
    CONSTRAINT fk_products_category
        FOREIGN KEY (category_id) REFERENCES dim_categories(category_id)
);

CREATE TABLE dim_customers (
    customer_id         INT             PRIMARY KEY,
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    full_name           VARCHAR(200),
    email                VARCHAR(255),
    phone_clean          VARCHAR(50),
    country              VARCHAR(100),
    city                 VARCHAR(100),
    loyalty_score        INT             NOT NULL DEFAULT 500,
    registration_date    DATE
);

CREATE TABLE fct_orders (
    order_id              INT             PRIMARY KEY,
    customer_id           INT             NOT NULL,
    product_id            INT             NOT NULL,
    currency_code          CHAR(3)         NOT NULL,
    order_date             DATE            NOT NULL,
    order_status           VARCHAR(20)     NOT NULL,
    quantity               INT             NOT NULL,
    unit_price_native       DECIMAL(15,2)   NOT NULL,
    unit_price_usd          DECIMAL(15,2)   NOT NULL,
    gross_amount_usd         DECIMAL(15,2)   NOT NULL,
    discount_pct             DECIMAL(5,2)    NOT NULL DEFAULT 0.00,
    discount_amount_usd       DECIMAL(15,2)   NOT NULL DEFAULT 0.00,
    shipping_fee_usd          DECIMAL(15,2)   NOT NULL DEFAULT 0.00,
    net_revenue_usd            DECIMAL(15,2)   NOT NULL,
    CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES dim_customers(customer_id),
    CONSTRAINT fk_orders_product  FOREIGN KEY (product_id)  REFERENCES dim_products(product_id),
    CONSTRAINT fk_orders_currency FOREIGN KEY (currency_code) REFERENCES dim_currencies(currency_code)
);

CREATE TABLE fct_logistics (
    order_id              INT             PRIMARY KEY,
    carrier_name           VARCHAR(100)    NOT NULL DEFAULT 'Unassigned',
    tracking_number        VARCHAR(100),
    ship_date               DATE,
    shipping_lead_days       INT,
    warehouse_origin         VARCHAR(100),
    CONSTRAINT fk_logistics_order FOREIGN KEY (order_id) REFERENCES fct_orders(order_id)
);


-- ============================================================================
-- PHASE 6: VIEWS & REPORTING LAYER
-- ============================================================================

CREATE OR REPLACE VIEW vw_monthly_revenue_dashboard AS
SELECT
    YEAR(fo.order_date)  AS order_year,
    MONTH(fo.order_date) AS order_month,
    dc.category_name,
    SUM(fo.quantity) AS units_sold,
    SUM(fo.net_revenue_usd) AS net_revenue,
    SUM(fo.net_revenue_usd) - SUM(fo.quantity * dp.unit_cost_usd) AS gross_profit
FROM fct_orders fo
JOIN dim_products dp ON dp.product_id = fo.product_id
JOIN dim_categories dc ON dc.category_id = dp.category_id
GROUP BY order_year, order_month, dc.category_name;

CREATE OR REPLACE VIEW vw_customer_360 AS
SELECT
    dcu.customer_id,
    dcu.full_name,
    COUNT(fo.order_id) AS lifetime_order_count,
    COALESCE(SUM(fo.net_revenue_usd), 0) AS total_spend,
    ROUND(AVG(fo.net_revenue_usd), 2) AS avg_order_value,
    MAX(fo.order_date) AS last_order_date,
    CASE
        WHEN dcu.loyalty_score >= 800 THEN 'Platinum'
        WHEN dcu.loyalty_score >= 600 THEN 'Gold'
        WHEN dcu.loyalty_score >= 400 THEN 'Silver'
        ELSE 'Bronze'
    END AS loyalty_tier
FROM dim_customers dcu
LEFT JOIN fct_orders fo ON fo.customer_id = dcu.customer_id
GROUP BY dcu.customer_id, dcu.full_name, dcu.loyalty_score;

CREATE OR REPLACE VIEW vw_dead_stock_alert AS
SELECT
    dp.product_id,
    dp.product_name,
    dc.category_name,
    dp.warehouse_stock,
    ROUND(dp.warehouse_stock * dp.unit_cost_usd, 2) AS capital_tied_up
FROM dim_products dp
JOIN dim_categories dc ON dc.category_id = dp.category_id
LEFT JOIN fct_orders fo ON fo.product_id = dp.product_id
WHERE fo.order_id IS NULL;

-- ============================================================================
