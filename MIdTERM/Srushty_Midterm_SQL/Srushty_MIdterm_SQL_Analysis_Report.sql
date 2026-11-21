=============================================================

-- =============================================================================
-- PART 0: DATA IMPORT
-- =============================================================================


PRAGMA foreign_keys = ON;

DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS menu_items;

-- Lookup table: one row per menu item with its fixed price
CREATE TABLE menu_items (
    item_name   TEXT PRIMARY KEY,
    unit_price  REAL NOT NULL CHECK (unit_price > 0)
);

-- Fact table: one row per sale. NULL = value was not recorded in the source data.
CREATE TABLE transactions (
    transaction_id   TEXT PRIMARY KEY
                     CHECK (transaction_id GLOB 'TXN_[0-9][0-9][0-9][0-9][0-9][0-9][0-9]'),
    item             TEXT REFERENCES menu_items (item_name),
    quantity         INTEGER CHECK (quantity BETWEEN 1 AND 5),
    price_per_unit   REAL    CHECK (price_per_unit > 0),
    total_spent      REAL    CHECK (total_spent > 0),
    payment_method   TEXT    CHECK (payment_method IN ('Cash', 'Credit Card', 'Digital Wallet')),
    location         TEXT    CHECK (location IN ('In-store', 'Takeaway')),
    transaction_date TEXT    CHECK (transaction_date IS NULL OR date(transaction_date) = transaction_date),
    -- when all three are present, the arithmetic must hold
    CHECK (quantity IS NULL OR price_per_unit IS NULL OR total_spent IS NULL
           OR ABS(quantity * price_per_unit - total_spent) < 0.001)
);

CREATE INDEX idx_transactions_date ON transactions (transaction_date);
CREATE INDEX idx_transactions_item ON transactions (item);

-- ---------------------------------------------------------------------------
-- DATA IMPORT (SQLite command-line shell)
-- Run these from the folder that contains cafe_sales_cleaned.csv. They are
-- shown as comments because the dot-commands only work in the sqlite3 shell.
-- (The accompanying cafe_sales.db was loaded with the same logic.)
--
  CREATE TEMP TABLE staging (
      transaction_id TEXT, item TEXT, quantity TEXT, price_per_unit TEXT,
      total_spent TEXT, payment_method TEXT, location TEXT, transaction_date TEXT);
  .mode csv
  .import --skip 1 cafe_sales_cleaned.csv staging

  INSERT INTO menu_items (item_name, unit_price)
  SELECT item, MAX(CAST(price_per_unit AS REAL))
  FROM staging WHERE item <> '' AND price_per_unit <> '' GROUP BY item;

  INSERT INTO transactions
  SELECT transaction_id,
         NULLIF(item, ''),
         CAST(NULLIF(quantity, '') AS INTEGER),
         CAST(NULLIF(price_per_unit, '') AS REAL),
         CAST(NULLIF(total_spent, '') AS REAL),
         NULLIF(payment_method, ''),
         NULLIF(location, ''),
         NULLIF(transaction_date, '')
  FROM staging;
  .mode column
  .headers on
-- ---------------------------------------------------------------------------
-- =============================================================================
-- PART 1: DATA VERIFICATION
-- =============================================================================

-- [V1] Row count matches the source file
-- Purpose: The cleaned CSV and the original dirty CSV each have 10,000 data rows, so the table
-- should too.
SELECT COUNT(*)            AS rows_in_table,
       10000               AS rows_in_source_csv,
       COUNT(*) = 10000    AS counts_match
FROM transactions;
-- Sample result (1 of 1 rows):
--   rows_in_table rows_in_source_csv counts_match
--           10000              10000            1

-- [V2] Primary key is unique and complete
-- Purpose: Every row should have a distinct, non-null Transaction ID.
SELECT COUNT(*)                      AS total_rows,
       COUNT(DISTINCT transaction_id)  AS distinct_ids,
       SUM(transaction_id IS NULL)     AS null_ids
FROM transactions;
-- Sample result (1 of 1 rows):
--   total_rows distinct_ids null_ids
--        10000        10000        0

-- [V3] Missing values per column
-- Purpose: Shows how many values are NULL (not recorded) in each column after import.
SELECT SUM(item IS NULL)             AS item,
       SUM(quantity IS NULL)         AS quantity,
       SUM(price_per_unit IS NULL)   AS price_per_unit,
       SUM(total_spent IS NULL)      AS total_spent,
       SUM(payment_method IS NULL)   AS payment_method,
       SUM(location IS NULL)         AS location,
       SUM(transaction_date IS NULL) AS transaction_date
FROM transactions;
-- Sample result (1 of 1 rows):
--   item quantity price_per_unit total_spent payment_method location transaction_date
--    480       23              6          23           3178     3961              460

-- [V4] Data type check
-- Purpose: Every stored value should have the expected SQLite storage type (or be NULL). All
-- counts should be 0.
SELECT SUM(typeof(quantity)         NOT IN ('integer', 'null')) AS bad_quantity_type,
       SUM(typeof(price_per_unit)   NOT IN ('real', 'integer', 'null')) AS bad_price_type,
       SUM(typeof(total_spent)      NOT IN ('real', 'integer', 'null')) AS bad_total_type,
       SUM(typeof(transaction_date) NOT IN ('text', 'null')) AS bad_date_type,
       SUM(transaction_date IS NOT NULL AND date(transaction_date) IS NOT transaction_date) AS bad_date_format
FROM transactions;
-- Sample result (1 of 1 rows):
--   bad_quantity_type bad_price_type bad_total_type bad_date_type bad_date_format
--                   0              0              0             0               0

-- =============================================================================
-- PART 2: EXPLORATORY QUERIES
-- =============================================================================

-- [E1] Counts of records meeting specific criteria
-- Analysis type: Count
-- Purpose: How many sales are large, how many involve bigger baskets paid by digital wallet, and
-- how many records are missing key fields? Sizes the data-quality problem before any analysis.
SELECT COUNT(*)                                              AS total_rows,
       SUM(total_spent >= 20)                                 AS orders_20_or_more,
       SUM(quantity >= 4 AND payment_method = 'Digital Wallet') AS big_basket_wallet,
       SUM(payment_method IS NULL)                            AS no_payment_method,
       SUM(location IS NULL)                                  AS no_location,
       SUM(item IS NULL)                                      AS no_item,
       SUM(transaction_date IS NULL)                          AS no_date
FROM transactions;
-- Sample result (1 of 1 rows):
--   total_rows orders_20_or_more big_basket_wallet no_payment_method no_location no_item no_date
--        10000              1058               927              3178        3961     480     460

-- [E2] Revenue and average order by item (SUM / AVG with GROUP BY)
-- Analysis type: Sum/average with grouping
-- Purpose: Which items bring in the most money, and what does a typical order for each look like?
SELECT COALESCE(item, 'Not recorded')   AS item,
       COUNT(*)                        AS transactions,
       SUM(quantity)                   AS units_sold,
       ROUND(SUM(total_spent), 2)      AS revenue,
       ROUND(AVG(total_spent), 2)      AS avg_order_value
FROM transactions
GROUP BY COALESCE(item, 'Not recorded')
ORDER BY revenue DESC;
-- Sample result (9 of 9 rows):
--           item transactions units_sold  revenue avg_order_value
--          Salad         1272       3819  19095.0           15.04
--       Sandwich         1131       3429  13716.0           12.17
--       Smoothie         1096       3336  13344.0            12.2
--          Juice         1171       3505  10515.0             9.0
--           Cake         1139       3468  10404.0            9.14
--         Coffee         1291       3904   7808.0            6.07
--            Tea         1207       3650   5475.0            4.54
--   Not recorded          480       1471   5141.0           10.78
--         Cookie         1213       3598   3598.0            2.97

-- [E3] Smallest and largest values (MIN / MAX)
-- Analysis type: Minimum / maximum
-- Purpose: What are the extremes of order size, price and dates, and which sale was the largest?
SELECT MIN(total_spent)            AS smallest_order,
       MAX(total_spent)            AS largest_order,
       MIN(price_per_unit)         AS cheapest_unit_price,
       MAX(price_per_unit)         AS priciest_unit_price,
       MIN(transaction_date)       AS first_sale_date,
       MAX(transaction_date)       AS last_sale_date,
       (SELECT transaction_id FROM transactions
        ORDER BY total_spent DESC, transaction_id LIMIT 1) AS a_largest_order_id
FROM transactions;
-- Sample result (1 of 1 rows):
--   smallest_order largest_order cheapest_unit_price priciest_unit_price first_sale_date last_sale_date a_largest_order_id
--              1.0          25.0                 1.0                 5.0      2023-01-01     2023-12-31        TXN_1037486

-- [E4] Fourth-quarter sales by month (date filtering)
-- Analysis type: Date-based filtering
-- Purpose: How did October to December 2023 perform? Uses a date range filter and month grouping.
SELECT strftime('%Y-%m', transaction_date) AS month,
       COUNT(*)                              AS transactions,
       ROUND(SUM(total_spent), 2)            AS revenue,
       ROUND(AVG(total_spent), 2)            AS avg_order_value
FROM transactions
WHERE transaction_date BETWEEN '2023-10-01' AND '2023-12-31'
GROUP BY month
ORDER BY month;
-- Sample result (3 of 3 rows):
--     month transactions revenue avg_order_value
--   2023-10          838  7314.0            8.74
--   2023-11          784  6967.0            8.89
--   2023-12          795  7177.0            9.07


-- =============================================================================
-- PART 3: BUSINESS QUERIES (ADVANCED)
-- =============================================================================

-- [B1] Monthly revenue trend with month-over-month change, moving average and running total
-- Analysis type: Time series, moving average, running total
-- Purpose: Is revenue growing, shrinking or seasonal? Shows each month with its change from the
-- prior month, a 3-month moving average that smooths noise, and cumulative revenue for the year.
WITH monthly AS (
    SELECT strftime('%Y-%m', transaction_date) AS month,
           COUNT(*)                            AS transactions,
           ROUND(SUM(total_spent), 2)          AS revenue
    FROM transactions
    WHERE transaction_date IS NOT NULL
    GROUP BY month
)
SELECT month,
       transactions,
       revenue,
       ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
             / LAG(revenue) OVER (ORDER BY month), 1)                      AS mom_change_pct,
       ROUND(AVG(revenue) OVER (ORDER BY month
             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)                 AS moving_avg_3m,
       ROUND(SUM(revenue) OVER (ORDER BY month), 2)                        AS running_total
FROM monthly
ORDER BY month;
-- Sample result (12 of 12 rows):
--     month transactions revenue mom_change_pct moving_avg_3m running_total
--   2023-01          818  7254.0           NULL        7254.0        7254.0
--   2023-02          727  6644.0           -8.4        6949.0       13898.0
--   2023-03          827  7216.0            8.6        7038.0       21114.0
--   2023-04          774  7179.0           -0.5        7013.0       28293.0
--   2023-05          777  6957.5           -3.1        7117.5       35250.5
--   2023-06          818  7353.0            5.7       7163.17       42603.5
--   2023-07          791  6877.5           -6.5       7062.67       49481.0
--   2023-08          803  7112.5            3.4       7114.33       56593.5
--   2023-09          788  6871.0           -3.4       6953.67       63464.5
--   2023-10          838  7314.0            6.4       7099.17       70778.5
--   2023-11          784  6967.0           -4.7       7050.67       77745.5
--   2023-12          795  7177.0            3.0       7152.67       84922.5

-- [B2] Item ranking with share of revenue and cumulative (Pareto) share
-- Analysis type: Ranking
-- Purpose: Which items matter most? Ranks items by revenue and by units, and shows the cumulative
-- share so we can see how few items make up most of sales. Comparing the two ranks tests whether
-- revenue is driven by volume or by price.
WITH item_totals AS (
    SELECT COALESCE(item, 'Not recorded') AS item,
           SUM(quantity)                  AS units,
           ROUND(SUM(total_spent), 2)     AS revenue
    FROM transactions
    GROUP BY COALESCE(item, 'Not recorded')
)
SELECT item,
       units,
       revenue,
       RANK() OVER (ORDER BY revenue DESC) AS revenue_rank,
       RANK() OVER (ORDER BY units DESC)   AS units_rank,
       ROUND(100.0 * revenue / SUM(revenue) OVER (), 1) AS pct_of_revenue,
       ROUND(100.0 * SUM(revenue) OVER (ORDER BY revenue DESC
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
             / SUM(revenue) OVER (), 1)                  AS cumulative_pct
FROM item_totals
ORDER BY revenue_rank;
-- Sample result (9 of 9 rows):
--           item units  revenue revenue_rank units_rank pct_of_revenue cumulative_pct
--          Salad  3819  19095.0            1          2           21.4           21.4
--       Sandwich  3429  13716.0            2          7           15.4           36.8
--       Smoothie  3336  13344.0            3          8           15.0           51.8
--          Juice  3505  10515.0            4          5           11.8           63.6
--           Cake  3468  10404.0            5          6           11.7           75.3
--         Coffee  3904   7808.0            6          1            8.8           84.0
--            Tea  3650   5475.0            7          3            6.1           90.2
--   Not recorded  1471   5141.0            8          9            5.8           96.0
--         Cookie  3598   3598.0            9          4            4.0          100.0

-- [B3] Order-value deciles (percentile analysis)
-- Analysis type: Percentiles
-- Purpose: How concentrated is revenue across order sizes? Splits all priced transactions into ten
-- equal-sized groups by order value and shows each group's share of revenue.
WITH ranked AS (
    SELECT total_spent,
           NTILE(10) OVER (ORDER BY total_spent) AS decile
    FROM transactions
    WHERE total_spent IS NOT NULL
)
SELECT decile,
       COUNT(*)                    AS transactions,
       MIN(total_spent)            AS min_order,
       MAX(total_spent)            AS max_order,
       ROUND(SUM(total_spent), 2)  AS revenue,
       ROUND(100.0 * SUM(total_spent)
             / (SELECT SUM(total_spent) FROM transactions), 1) AS pct_of_revenue
FROM ranked
GROUP BY decile
ORDER BY decile;
-- Sample result (10 of 10 rows):
--   decile transactions min_order max_order  revenue pct_of_revenue
--        1          998       1.0       3.0   1660.0            1.9
--        2          998       3.0       4.0   3043.0            3.4
--        3          998       4.0       4.5   4031.0            4.5
--        4          998       4.5       6.0   5252.0            5.9
--        5          998       6.0       8.0   6505.0            7.3
--        6          998       8.0       9.0   8333.0            9.4
--        7          998       9.0      12.0  10409.0           11.7
--        8          997      12.0      15.0  12852.0           14.4
--        9          997      15.0      20.0  15726.0           17.7
--       10          997      20.0      25.0  21285.0           23.9

-- [B4] Price-tier cohorts by quarter
-- Analysis type: Cohort analysis (grouping related records)
-- Purpose: Groups sales into related cohorts by price tier (Budget, Standard, Premium) and follows
-- each cohort across the four quarters. Shows whether the product mix is shifting over the year.
SELECT CASE WHEN price_per_unit <= 2 THEN '1 Budget (up to $2)'
            WHEN price_per_unit <= 4 THEN '2 Standard ($3-$4)'
            ELSE                          '3 Premium ($5)' END   AS price_cohort,
       ROUND(SUM(CASE WHEN CAST(strftime('%m', transaction_date) AS INTEGER) BETWEEN 1  AND 3  THEN total_spent END), 0) AS q1,
       ROUND(SUM(CASE WHEN CAST(strftime('%m', transaction_date) AS INTEGER) BETWEEN 4  AND 6  THEN total_spent END), 0) AS q2,
       ROUND(SUM(CASE WHEN CAST(strftime('%m', transaction_date) AS INTEGER) BETWEEN 7  AND 9  THEN total_spent END), 0) AS q3,
       ROUND(SUM(CASE WHEN CAST(strftime('%m', transaction_date) AS INTEGER) BETWEEN 10 AND 12 THEN total_spent END), 0) AS q4,
       ROUND(SUM(total_spent), 0)                                AS total,
       ROUND(100.0 * SUM(total_spent) /
             (SELECT SUM(total_spent) FROM transactions
              WHERE price_per_unit IS NOT NULL AND transaction_date IS NOT NULL), 1) AS pct_of_dated_revenue
FROM transactions
WHERE price_per_unit IS NOT NULL AND transaction_date IS NOT NULL
GROUP BY price_cohort
ORDER BY price_cohort;
-- Sample result (3 of 3 rows):
--          price_cohort       q1       q2       q3       q4    total pct_of_dated_revenue
--   1 Budget (up to $2)   4089.0   3826.0   4073.0   4133.0  16121.0                 19.0
--    2 Standard ($3-$4)  12470.0  13014.0  12228.0  12816.0  50528.0                 59.5
--        3 Premium ($5)   4555.0   4625.0   4540.0   4500.0  18220.0                 21.5

-- [B5] High-value in-store card/wallet orders in the second half of the year
-- Analysis type: Complex filtering with multiple conditions
-- Purpose: Where do large, in-store, electronic-payment orders come from in H2 2023? Combines six
-- conditions (value, quantity, channel, payment type, date, minimum group size) to profile the
-- most valuable customer-facing segment.
SELECT item,
       payment_method,
       COUNT(*)                    AS big_orders,
       ROUND(SUM(total_spent), 2)  AS revenue,
       ROUND(AVG(total_spent), 2)  AS avg_order_value
FROM transactions
WHERE total_spent >= 15
  AND quantity >= 3
  AND location = 'In-store'
  AND payment_method IN ('Credit Card', 'Digital Wallet')
  AND transaction_date >= '2023-07-01'
GROUP BY item, payment_method
HAVING COUNT(*) >= 10
ORDER BY revenue DESC
LIMIT 10;
-- Sample result (5 of 5 rows):
--       item payment_method big_orders revenue avg_order_value
--      Salad Digital Wallet         36   725.0           20.14
--      Salad    Credit Card         29   565.0           19.48
--   Smoothie Digital Wallet         23   408.0           17.74
--   Sandwich Digital Wallet         19   356.0           18.74
--   Sandwich    Credit Card         12   216.0            18.0

