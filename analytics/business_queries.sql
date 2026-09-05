-- ============================================================================
-- TERRAPULSE_DW — BUSINESS INTELLIGENCE QUERIES (Phase 4: BI + Phase 5: Transactions)
-- Target: MySQL 8.0+
-- Run schema/terrapulse_ddl.sql and etl/cleaning_pipeline.sql first.
-- ============================================================================

USE terrapulse_dw;

-- PHASE 4: BUSINESS INTELLIGENCE QUERIES
-- ============================================================================

-- Q4.1 Revenue & profitability by category (Delivered + Shipped only)
SELECT
    dc.category_name,
    SUM(fo.quantity) AS units_sold,
    SUM(fo.gross_amount_usd) AS gross_revenue,
    SUM(fo.discount_amount_usd) AS total_discounts_lost,
    SUM(fo.net_revenue_usd) AS net_revenue,
    SUM(fo.quantity * dp.unit_cost_usd) AS total_cost,
    SUM(fo.net_revenue_usd) - SUM(fo.quantity * dp.unit_cost_usd) AS gross_profit,
    ROUND(100 * (SUM(fo.net_revenue_usd) - SUM(fo.quantity * dp.unit_cost_usd)) / NULLIF(SUM(fo.net_revenue_usd),0), 2) AS profit_margin_pct
FROM fct_orders fo
JOIN dim_products dp ON dp.product_id = fo.product_id
JOIN dim_categories dc ON dc.category_id = dp.category_id
WHERE fo.order_status IN ('Delivered', 'Shipped')
GROUP BY dc.category_name
ORDER BY net_revenue DESC;

-- Q4.2 Geographic revenue distribution
SELECT
    dcu.country,
    COUNT(*) AS order_count,
    SUM(fo.net_revenue_usd) AS net_revenue,
    ROUND(100 * SUM(fo.net_revenue_usd) / SUM(SUM(fo.net_revenue_usd)) OVER (), 2) AS pct_of_global_revenue
FROM fct_orders fo
JOIN dim_customers dcu ON dcu.customer_id = fo.customer_id
GROUP BY dcu.country
ORDER BY net_revenue DESC;

-- Q4.3 Currency exposure analysis
SELECT
    fo.currency_code,
    COUNT(*) AS order_count,
    SUM(fo.unit_price_native * fo.quantity) AS native_revenue_total,
    SUM(fo.gross_amount_usd) AS usd_equivalent,
    ROUND(100 * SUM(fo.gross_amount_usd) / SUM(SUM(fo.gross_amount_usd)) OVER (), 2) AS pct_global_share
FROM fct_orders fo
GROUP BY fo.currency_code
ORDER BY usd_equivalent DESC;
-- Highest currency risk = the non-USD currency with the largest pct_global_share.

-- Q4.4 Carrier SLA performance audit
SELECT
    fl.carrier_name,
    COUNT(*) AS total_shipments,
    ROUND(AVG(fl.shipping_lead_days), 1) AS avg_lead_days,
    MAX(fl.shipping_lead_days) AS max_lead_days,
    CASE
        WHEN AVG(fl.shipping_lead_days) <= 3 THEN 'Tier 1 - Excellent'
        WHEN AVG(fl.shipping_lead_days) <= 7 THEN 'Tier 2 - Acceptable'
        ELSE 'Tier 3 - At Risk'
    END AS sla_tier
FROM fct_logistics fl
GROUP BY fl.carrier_name
ORDER BY avg_lead_days ASC;

-- Q4.5 Customer value segmentation
SELECT
    dcu.customer_id,
    dcu.full_name,
    SUM(fo.net_revenue_usd) AS lifetime_spend,
    COUNT(*) AS order_count,
    ROUND(AVG(fo.net_revenue_usd), 2) AS avg_order_value,
    CASE
        WHEN SUM(fo.net_revenue_usd) >= 20000 THEN 'Platinum'
        WHEN SUM(fo.net_revenue_usd) >= 10000 THEN 'Gold'
        WHEN SUM(fo.net_revenue_usd) >= 2000  THEN 'Silver'
        ELSE 'Bronze'
    END AS customer_segment
FROM fct_orders fo
JOIN dim_customers dcu ON dcu.customer_id = fo.customer_id
GROUP BY dcu.customer_id, dcu.full_name
ORDER BY lifetime_spend DESC;

-- Q4.6 Dormant customer anti-join
SELECT
    dcu.customer_id,
    dcu.full_name,
    dcu.country,
    dcu.registration_date,
    DATEDIFF(CURDATE(), dcu.registration_date) AS days_since_registration
FROM dim_customers dcu
LEFT JOIN fct_orders fo ON fo.customer_id = dcu.customer_id
WHERE fo.order_id IS NULL
ORDER BY days_since_registration DESC;

-- Q4.7 Dead stock & capital audit
SELECT
    dp.product_name,
    dc.category_name,
    dp.retail_price_usd,
    dp.warehouse_stock,
    ROUND(dp.warehouse_stock * dp.unit_cost_usd, 2) AS capital_tied_up
FROM dim_products dp
JOIN dim_categories dc ON dc.category_id = dp.category_id
LEFT JOIN fct_orders fo ON fo.product_id = dp.product_id
WHERE fo.order_id IS NULL
ORDER BY capital_tied_up DESC;

-- Q4.8 Monthly revenue trend, 2023 vs 2024
SELECT
    MONTHNAME(fo.order_date) AS month_name,
    MONTH(fo.order_date) AS month_num,
    SUM(CASE WHEN YEAR(fo.order_date) = 2023 THEN fo.net_revenue_usd ELSE 0 END) AS revenue_2023,
    SUM(CASE WHEN YEAR(fo.order_date) = 2024 THEN fo.net_revenue_usd ELSE 0 END) AS revenue_2024
FROM fct_orders fo
WHERE YEAR(fo.order_date) IN (2023, 2024)
GROUP BY month_num, month_name
ORDER BY month_num;


-- ============================================================================
-- PHASE 5: TRANSACTIONS & DATA INTEGRITY
-- ============================================================================

START TRANSACTION;

-- 5.2 +15% cost increase on Renewable Energy & Solar products
UPDATE dim_products dp
JOIN dim_categories dc ON dc.category_id = dp.category_id
SET dp.unit_cost_usd = ROUND(dp.unit_cost_usd * 1.15, 2)
WHERE dc.category_name = 'Renewable Energy & Solar';

SAVEPOINT after_solar_update;

-- 5.4 Deliberate error: junior analyst destroys all prices
UPDATE dim_products SET unit_cost_usd = 50.00;

-- 5.5 Demonstrate the corrupted state
SELECT product_id, product_name, unit_cost_usd FROM dim_products LIMIT 10;

-- 5.6 Roll back the bad update only
ROLLBACK TO SAVEPOINT after_solar_update;

-- 5.7 Correct +8% cost increase on EV Mobility & Charging products
UPDATE dim_products dp
JOIN dim_categories dc ON dc.category_id = dp.category_id
SET dp.unit_cost_usd = ROUND(dp.unit_cost_usd * 1.08, 2)
WHERE dc.category_name = 'EV Mobility & Charging';

COMMIT;

-- Final confirmation
SELECT dc.category_name, dp.product_name, dp.unit_cost_usd
FROM dim_products dp
JOIN dim_categories dc ON dc.category_id = dp.category_id
WHERE dc.category_name IN ('Renewable Energy & Solar', 'EV Mobility & Charging')
ORDER BY dc.category_name, dp.product_name;


-- ============================================================================
