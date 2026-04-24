--Customer Overview
SELECT
    COUNT(*)                            AS total_customers,
    COUNT(DISTINCT acquisition_channel) AS total_channels,
    COUNT(DISTINCT state)               AS total_states,
    MIN(registration_date)                    AS earliest_signup,
    MAX(registration_date)                    AS latest_signup,
    DATEDIFF(DAY, MIN(registration_date), MAX(registration_date)) AS signup_window_days
FROM clv_customer;

--Transaction Overview
SELECT
    COUNT(DISTINCT customer_id)                         AS customers_with_transactions,
    COUNT(transaction_id)                               AS total_transactions,
    ROUND(SUM(CAST(gross_amount AS FLOAT)), 2)          AS total_revenue,
    ROUND(AVG(CAST(gross_amount AS FLOAT)), 2)          AS avg_transaction_value,
    ROUND(MIN(CAST(gross_amount AS FLOAT)), 2)          AS min_transaction,
    ROUND(MAX(CAST(gross_amount AS FLOAT)), 2)          AS max_transaction,
    ROUND(STDEV(CAST(gross_amount AS FLOAT)), 2)        AS stddev_transaction
FROM clv_transactions;

--One-Time Buyers vs Repeat Buyers
SELECT
    tx_count,
    COUNT(*)                                                        AS num_customers,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)             AS pct_customers
FROM (
    SELECT customer_id, COUNT(*) AS tx_count
    FROM clv_transactions
    GROUP BY customer_id
) t
GROUP BY tx_count
ORDER BY tx_count;

--Historical CLV per Customer
SELECT
    c.customer_id,
    c.full_name,
    c.acquisition_channel,
    c.state,
    COUNT(t.transaction_id)                                             AS total_transactions,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)), 2)                        AS historical_clv,
    ROUND(AVG(CAST(t.gross_amount AS FLOAT)), 2)                        AS avg_order_value,
    MIN(t.transaction_date)                                             AS first_purchase,
    MAX(t.transaction_date)                                             AS last_purchase,
    DATEDIFF(DAY, MIN(t.transaction_date), MAX(t.transaction_date))     AS customer_lifespan_days
FROM clv_customer c
LEFT JOIN clv_transactions t ON c.customer_id = t.customer_id
GROUP BY c.customer_id, c.full_name, c.acquisition_channel, c.state
ORDER BY historical_clv DESC;

--Estimated CLV
SELECT
    customer_id,
    full_name,
    historical_clv,
    total_transactions,
    avg_order_value,
    customer_lifespan_days,
    ROUND(total_transactions / NULLIF(customer_lifespan_days / 365.0, 0), 2) AS purchases_per_year,
    ROUND(
        avg_order_value
        * (total_transactions / NULLIF(customer_lifespan_days / 365.0, 0))
        * 1
    , 2) AS estimated_clv_1yr
FROM (
    SELECT
        c.customer_id,
        c.full_name,
        COUNT(t.transaction_id)                                             AS total_transactions,
        ROUND(SUM(CAST(t.gross_amount AS FLOAT)), 2)                        AS historical_clv,
        ROUND(AVG(CAST(t.gross_amount AS FLOAT)), 2)                        AS avg_order_value,
        NULLIF(DATEDIFF(DAY, MIN(t.transaction_date), MAX(t.transaction_date)), 0) AS customer_lifespan_days
    FROM clv_customer c
    JOIN clv_transactions t ON c.customer_id = t.customer_id
    GROUP BY c.customer_id, c.full_name
) base
ORDER BY estimated_clv_1yr DESC;

--minimum lifespan treshold
SELECT
    customer_id,
    full_name,
    historical_clv,
    total_transactions,
    avg_order_value,
    customer_lifespan_days,
    ROUND(total_transactions / NULLIF(customer_lifespan_days / 365.0, 0), 2) AS purchases_per_year,
    CASE 
        WHEN customer_lifespan_days < 30 THEN NULL  -- insufficient history
        ELSE ROUND(
            avg_order_value
            * (total_transactions / NULLIF(customer_lifespan_days / 365.0, 0))
        , 2)
    END AS estimated_clv_1yr
FROM (
    SELECT
        c.customer_id,
        c.full_name,
        COUNT(t.transaction_id)                                             AS total_transactions,
        ROUND(SUM(CAST(t.gross_amount AS FLOAT)), 2)                        AS historical_clv,
        ROUND(AVG(CAST(t.gross_amount AS FLOAT)), 2)                        AS avg_order_value,
        NULLIF(DATEDIFF(DAY, MIN(t.transaction_date), MAX(t.transaction_date)), 0) AS customer_lifespan_days
    FROM clv_customer c
    JOIN clv_transactions t ON c.customer_id = t.customer_id
    GROUP BY c.customer_id, c.full_name
) base
ORDER BY estimated_clv_1yr DESC;


--RFM Scoring
WITH rfm_raw AS (
    SELECT
        customer_id,
        DATEDIFF(DAY, MAX(CAST(transaction_date AS DATE)), CAST(GETDATE() AS DATE)) AS recency_days,
        COUNT(transaction_id)                                                         AS frequency,
        ROUND(SUM(CAST(gross_amount AS FLOAT)), 2)                                    AS monetary
    FROM clv_transactions
    GROUP BY customer_id
),
rfm_scored AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days ASC)  AS r_score,
        NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score,
        NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_raw
)
SELECT
    customer_id,
    recency_days,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    ROUND((r_score + f_score + m_score) / 3.0, 2) AS rfm_avg_score,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score <= 2                  THEN 'New Customers'
        WHEN r_score >= 3 AND f_score <= 2 AND m_score >= 3 THEN 'Promising'
        WHEN r_score <= 2 AND f_score >= 3 AND m_score >= 3 THEN 'At Risk'
        WHEN r_score <= 2 AND f_score >= 4 AND m_score >= 4 THEN 'Cant Lose Them'
        WHEN r_score <= 2 AND f_score <= 2                  THEN 'Lost'
        ELSE 'Need Attention'
    END AS customer_segment
FROM rfm_scored
ORDER BY rfm_avg_score DESC;


--Segment Summary
WITH rfm_raw AS (
    SELECT
        customer_id,
        DATEDIFF(DAY, MAX(CAST(transaction_date AS DATE)), CAST(GETDATE() AS DATE)) AS recency_days,
        COUNT(transaction_id)           AS frequency,
        ROUND(SUM(CAST(gross_amount AS FLOAT)), 2) AS monetary
    FROM clv_transactions
    GROUP BY customer_id
),
rfm_scored AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days ASC)  AS r_score,
        NTILE(5) OVER (ORDER BY frequency ASC)     AS f_score,
        NTILE(5) OVER (ORDER BY monetary ASC)      AS m_score
    FROM rfm_raw
),
segmented AS (
    SELECT *,
        CASE
            WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
            WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal Customers'
            WHEN r_score >= 4 AND f_score <= 2                  THEN 'New Customers'
            WHEN r_score >= 3 AND f_score <= 2 AND m_score >= 3 THEN 'Promising'
            WHEN r_score <= 2 AND f_score >= 3 AND m_score >= 3 THEN 'At Risk'
            WHEN r_score <= 2 AND f_score >= 4 AND m_score >= 4 THEN 'Cant Lose Them'
            WHEN r_score <= 2 AND f_score <= 2                  THEN 'Lost'
            ELSE 'Need Attention'
        END AS customer_segment
    FROM rfm_scored
)
SELECT
    customer_segment,
    COUNT(*)                                                        AS num_customers,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)             AS pct_customers,
    ROUND(SUM(monetary), 2)                                         AS total_revenue,
    ROUND(SUM(monetary) * 100.0 / SUM(SUM(monetary)) OVER (), 1)   AS pct_revenue,
    ROUND(AVG(monetary), 2)                                         AS avg_clv,
    ROUND(AVG(CAST(frequency AS FLOAT)), 1)                         AS avg_frequency,
    ROUND(AVG(CAST(recency_days AS FLOAT)), 0)                      AS avg_recency_days
FROM segmented
GROUP BY customer_segment
ORDER BY total_revenue DESC;


--Purchase Cadence
WITH ranked_transactions AS (
    SELECT
        customer_id,
        CAST(transaction_date AS DATE) AS transaction_date,
        LAG(CAST(transaction_date AS DATE)) OVER (
            PARTITION BY customer_id ORDER BY transaction_date
        ) AS prev_transaction_date
    FROM clv_transactions
),
gaps AS (
    SELECT
        customer_id,
        DATEDIFF(DAY, prev_transaction_date, transaction_date) AS days_between_purchases
    FROM ranked_transactions
    WHERE prev_transaction_date IS NOT NULL
)
SELECT
    ROUND(AVG(CAST(days_between_purchases AS FLOAT)), 0)    AS avg_days_between_purchases,
    MIN(days_between_purchases)                              AS min_days,
    MAX(days_between_purchases)                              AS max_days,
    ROUND(STDEV(days_between_purchases), 0)                  AS stddev_days,
    SUM(CASE WHEN days_between_purchases <= 30  THEN 1 ELSE 0 END) AS gap_under_30d,
    SUM(CASE WHEN days_between_purchases BETWEEN 31 AND 90 THEN 1 ELSE 0 END) AS gap_31_90d,
    SUM(CASE WHEN days_between_purchases > 90  THEN 1 ELSE 0 END)  AS gap_over_90d
FROM gaps;


--Churn Detection
WITH max_date AS (
    SELECT MAX(CAST(transaction_date AS DATE)) AS ref_date
    FROM clv_transactions
)
SELECT
    t.customer_id,
    c.full_name,
    c.acquisition_channel,
    MAX(CAST(t.transaction_date AS DATE))                                           AS last_transaction_date,
    DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date)                AS days_since_last_purchase,
    CASE
        WHEN DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date) > 246 * 3 THEN 'Churned'
        WHEN DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date) > 246 * 2 THEN 'High Risk'
        WHEN DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date) > 246     THEN 'At Risk'
        ELSE 'Active'
    END AS churn_status
FROM clv_transactions t
JOIN clv_customer c ON t.customer_id = c.customer_id
CROSS JOIN max_date m
GROUP BY t.customer_id, c.full_name, c.acquisition_channel, m.ref_date
ORDER BY days_since_last_purchase DESC;

-- Churn distribution summary
WITH max_date AS (
    SELECT MAX(CAST(transaction_date AS DATE)) AS ref_date
    FROM clv_transactions
)
SELECT
    churn_status,
    COUNT(*)                                                        AS num_customers,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)             AS pct_customers
FROM (
    SELECT
        t.customer_id,
        CASE
            WHEN DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date) > 246 * 3 THEN 'Churned'
            WHEN DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date) > 246 * 2 THEN 'High Risk'
            WHEN DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date) > 246     THEN 'At Risk'
            ELSE 'Active'
        END AS churn_status
    FROM clv_transactions t
    CROSS JOIN max_date m
    GROUP BY t.customer_id, m.ref_date
) summary
GROUP BY churn_status
ORDER BY num_customers DESC;


--CLV by Acquisition Channel
SELECT
    c.acquisition_channel,
    COUNT(DISTINCT c.customer_id)                                           AS total_customers,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)), 2)                            AS total_revenue,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)) 
          / COUNT(DISTINCT c.customer_id), 2)                               AS avg_clv_per_customer,
    ROUND(AVG(CAST(t.gross_amount AS FLOAT)), 2)                            AS avg_transaction_value,
    ROUND(COUNT(t.transaction_id) * 1.0 
          / COUNT(DISTINCT c.customer_id), 1)                               AS avg_transactions_per_customer,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)) * 100.0 
          / SUM(SUM(CAST(t.gross_amount AS FLOAT))) OVER (), 1)             AS pct_total_revenue
FROM clv_customer c
JOIN clv_transactions t ON c.customer_id = t.customer_id
GROUP BY c.acquisition_channel
ORDER BY avg_clv_per_customer DESC;

--Revenue by Product Category
SELECT
    category,
    COUNT(DISTINCT customer_id)                                             AS unique_buyers,
    COUNT(transaction_id)                                                   AS total_transactions,
    ROUND(SUM(CAST(gross_amount AS FLOAT)), 2)                              AS total_revenue,
    ROUND(AVG(CAST(gross_amount AS FLOAT)), 2)                              AS avg_transaction_value,
    ROUND(SUM(CAST(gross_amount AS FLOAT)) * 100.0 
          / SUM(SUM(CAST(gross_amount AS FLOAT))) OVER (), 1)               AS pct_revenue
FROM clv_transactions
GROUP BY category
ORDER BY total_revenue DESC;

--CLV by State
SELECT
    c.state,
    COUNT(DISTINCT c.customer_id)                                       AS total_customers,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)), 2)                        AS total_revenue,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)) 
          / COUNT(DISTINCT c.customer_id), 2)                           AS avg_clv_per_customer,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)) * 100.0 
          / SUM(SUM(CAST(t.gross_amount AS FLOAT))) OVER (), 1)         AS pct_revenue
FROM clv_customer c
JOIN clv_transactions t ON c.customer_id = t.customer_id
GROUP BY c.state
ORDER BY avg_clv_per_customer DESC;


--Pareto Analysis
WITH customer_revenue AS (
    SELECT
        customer_id,
        ROUND(SUM(CAST(gross_amount AS FLOAT)), 2) AS total_spent
    FROM clv_transactions
    GROUP BY customer_id
),
cumulative AS (
    SELECT
        customer_id,
        total_spent,
        ROUND(
            SUM(total_spent) OVER (ORDER BY total_spent DESC)
            / SUM(total_spent) OVER () * 100
        , 1) AS cumulative_revenue_pct,
        ROUND(
            ROW_NUMBER() OVER (ORDER BY total_spent DESC)
            * 100.0 / COUNT(*) OVER ()
        , 1) AS cumulative_customer_pct
    FROM customer_revenue
)
SELECT
    SUM(CASE WHEN cumulative_revenue_pct <= 80 THEN 1 ELSE 0 END)  AS customers_for_80pct_revenue,
    COUNT(*)                                                         AS total_customers,
    ROUND(
        SUM(CASE WHEN cumulative_revenue_pct <= 80 THEN 1 ELSE 0 END)
        * 100.0 / COUNT(*)
    , 1)                                                             AS pct_customers_for_80pct_revenue
FROM cumulative;

-- KPI Summary
WITH max_date AS (
    SELECT MAX(CAST(transaction_date AS DATE)) AS ref_date
    FROM clv_transactions
),
churn_base AS (
    SELECT
        t.customer_id,
        CASE
            WHEN DATEDIFF(DAY, MAX(CAST(t.transaction_date AS DATE)), m.ref_date) > 246 THEN 1
            ELSE 0
        END AS is_churned
    FROM clv_transactions t
    CROSS JOIN max_date m
    GROUP BY t.customer_id, m.ref_date
)
SELECT
    COUNT(DISTINCT c.customer_id)                                           AS total_customers,
    ROUND(SUM(CAST(t.gross_amount AS FLOAT)) 
          / COUNT(DISTINCT c.customer_id), 0)                               AS avg_clv,
    ROUND(SUM(cb.is_churned) * 100.0 / COUNT(cb.customer_id), 1)           AS churn_rate_pct,
    ROUND((1 - SUM(cb.is_churned) * 1.0 / COUNT(cb.customer_id)) * 100, 1) AS retention_rate_pct
FROM clv_customer c
JOIN clv_transactions t ON c.customer_id = t.customer_id
JOIN churn_base cb ON c.customer_id = cb.customer_id;