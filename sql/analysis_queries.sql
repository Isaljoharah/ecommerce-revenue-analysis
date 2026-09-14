-- ============================================================
-- E-commerce Revenue Analysis — Olist Store
-- Core SQL queries used in the analysis, in logical order
-- ============================================================

-- ------------------------------------------------------------
-- 1. TABLE CREATION
-- ------------------------------------------------------------

CREATE TABLE orders (
    order_id VARCHAR(50) PRIMARY KEY,
    customer_id VARCHAR(50),
    order_status VARCHAR(20),
    order_purchase_timestamp TIMESTAMP,
    order_approved_at TIMESTAMP,
    order_delivered_carrier_date TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

CREATE TABLE order_items (
    order_id VARCHAR(50),
    order_item_id INT,
    product_id VARCHAR(50),
    seller_id VARCHAR(50),
    shipping_limit_date TIMESTAMP,
    price DECIMAL(10,2),
    freight_value DECIMAL(10,2),
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE products (
    product_id VARCHAR(50) PRIMARY KEY,
    product_category_name VARCHAR(50),
    product_name_lenght INT,           -- typo present in original source data, kept as-is
    product_description_lenght INT,    -- same
    product_photos_qty INT,
    product_weight_g DECIMAL(10,3),
    product_length_cm DECIMAL(10,3),
    product_height_cm DECIMAL(10,3),
    product_width_cm DECIMAL(10,3)
);

CREATE TABLE category_translation (
    product_category_name VARCHAR(50) PRIMARY KEY,
    product_category_name_english VARCHAR(50)
);


-- ------------------------------------------------------------
-- 2. DATA VALIDATION — checking for unmapped categories
--    (used to justify excluding ~1.4% of revenue from analysis)
-- ------------------------------------------------------------

-- Find categories with no English translation, or no category at all
SELECT DISTINCT products.product_category_name
FROM products
WHERE products.product_category_name NOT IN (
    SELECT product_category_name FROM category_translation
) OR products.product_category_name IS NULL;

-- Quantify the revenue impact of those unmapped categories
SELECT SUM(order_items.price) AS total_missing_revenue
FROM order_items
JOIN products ON order_items.product_id = products.product_id
WHERE products.product_category_name NOT IN (
    SELECT product_category_name FROM category_translation
) OR products.product_category_name IS NULL;

-- Compare against total revenue to get the % impact (1.4%)
SELECT SUM(order_items.price) AS total_revenue
FROM order_items
JOIN orders ON order_items.order_id = orders.order_id
WHERE orders.order_status = 'delivered';


-- ------------------------------------------------------------
-- 3. IDENTIFYING THE RELIABLE TIME WINDOW
--    (monthly revenue trend — used to spot incomplete
--     data-collection months at the start/end of the dataset)
-- ------------------------------------------------------------

SELECT DATE_TRUNC('month', orders.order_purchase_timestamp) AS month,
       SUM(order_items.price) AS monthly_revenue
FROM order_items
JOIN orders ON order_items.order_id = orders.order_id
WHERE orders.order_status = 'delivered'
GROUP BY DATE_TRUNC('month', orders.order_purchase_timestamp)
ORDER BY month;

-- Conclusion: reliable window = 2017-01-01 to 2018-08-31


-- ------------------------------------------------------------
-- 4. MAIN ANALYSIS — revenue growth by category
--    (the core query: compares each category's revenue across
--     two periods, using a CTE + conditional aggregation)
-- ------------------------------------------------------------

WITH revenue AS (
    SELECT 
        category_translation.product_category_name_english,
        SUM(CASE WHEN orders.order_purchase_timestamp < '2017-11-01' 
                 THEN order_items.price ELSE 0 END) AS revenue_period1,
        SUM(CASE WHEN orders.order_purchase_timestamp >= '2017-11-01' 
                 THEN order_items.price ELSE 0 END) AS revenue_period2
    FROM order_items
    JOIN orders ON order_items.order_id = orders.order_id
    JOIN products ON order_items.product_id = products.product_id
    JOIN category_translation 
        ON category_translation.product_category_name = products.product_category_name
    WHERE orders.order_status = 'delivered'
      AND orders.order_purchase_timestamp BETWEEN '2017-01-01' AND '2018-08-31'
    GROUP BY category_translation.product_category_name_english
    HAVING SUM(order_items.price) > 100000  -- materiality threshold
)
SELECT 
    product_category_name_english,
    revenue_period1,
    revenue_period2,
    ROUND(((revenue_period2 - revenue_period1) / revenue_period1) * 100, 1) AS growth_pct
FROM revenue
ORDER BY revenue_period1 + revenue_period2 DESC;


-- ------------------------------------------------------------
-- 5. ROOT CAUSE — order count vs. average price
--    for the one declining category ('computers')
-- ------------------------------------------------------------

SELECT 
    COUNT(CASE WHEN orders.order_purchase_timestamp < '2017-11-01' 
               THEN order_items.order_id END) AS orders_period1,
    COUNT(CASE WHEN orders.order_purchase_timestamp >= '2017-11-01' 
               THEN order_items.order_id END) AS orders_period2,
    AVG(CASE WHEN orders.order_purchase_timestamp < '2017-11-01' 
             THEN order_items.price END) AS avg_price_period1,
    AVG(CASE WHEN orders.order_purchase_timestamp >= '2017-11-01' 
             THEN order_items.price END) AS avg_price_period2
FROM order_items
JOIN orders ON order_items.order_id = orders.order_id
JOIN products ON order_items.product_id = products.product_id
JOIN category_translation 
    ON category_translation.product_category_name = products.product_category_name
WHERE orders.order_status = 'delivered'
  AND orders.order_purchase_timestamp BETWEEN '2017-01-01' AND '2018-08-31'
  AND category_translation.product_category_name_english = 'computers';

-- Result: order count nearly flat (97 → 102); avg price dropped
-- from 1,337.85 to 871.69 — decline is price-driven, not demand-driven


-- ------------------------------------------------------------
-- 6. PRODUCT-LEVEL DRILL-DOWN
--    (the query that revealed WHY the average price dropped:
--     same products held their price; the catalog mix changed)
-- ------------------------------------------------------------

WITH product_performance AS (
    SELECT 
        order_items.product_id,
        COUNT(*) AS times_sold,
        AVG(CASE WHEN orders.order_purchase_timestamp < '2017-11-01' 
                 THEN order_items.price END) AS avg_price_period1,
        AVG(CASE WHEN orders.order_purchase_timestamp >= '2017-11-01' 
                 THEN order_items.price END) AS avg_price_period2
    FROM order_items
    JOIN orders ON order_items.order_id = orders.order_id
    JOIN products ON order_items.product_id = products.product_id
    JOIN category_translation 
        ON category_translation.product_category_name = products.product_category_name
    WHERE orders.order_status = 'delivered'
      AND orders.order_purchase_timestamp BETWEEN '2017-01-01' AND '2018-08-31'
      AND category_translation.product_category_name_english = 'computers'
    GROUP BY order_items.product_id
)
SELECT * FROM product_performance
ORDER BY times_sold DESC
LIMIT 15;


-- ------------------------------------------------------------
-- 7. CANCELLATION RATE (context metric, not a true return rate
--    — the source data has no explicit "return" field)
-- ------------------------------------------------------------

SELECT 
    COUNT(*) AS total_orders,
    COUNT(CASE WHEN order_status = 'canceled' THEN 1 END) AS canceled_orders,
    ROUND(COUNT(CASE WHEN order_status = 'canceled' THEN 1 END) * 100.0 / COUNT(*), 2) AS canceled_pct
FROM orders
WHERE order_purchase_timestamp BETWEEN '2017-01-01' AND '2018-08-31';
