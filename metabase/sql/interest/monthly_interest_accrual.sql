-- =====================================================================
-- Monthly interest accrual per dp_account.
--
-- Produces one row per (account, month) for the trailing 12 months,
-- containing:
--   - end_of_month_balance        running balance at the last day in scope
--   - transactions_on_last_day    count of portal-visible txns on that day
--   - monthly_transactions        count of portal-visible txns over the month
--   - days_present_in_month       how many days of the month are in scope
--   - calendar_days_in_month      total days in the calendar month
--   - is_partial_month            TRUE if the row covers less than the full month
--   - monthly_interest            client interest accrued in the month (ACT/365)
--   - carry                       firm's share of interest by account genre
--   - dp_interest                 firm's portion = monthly_interest * carry
--
-- Intended use: upsert into int_monthly / int_quarterly aggregations
-- and feed downstream commission calculations.
--
-- Differences from the prior version of this query:
--  [1] Series starts on the FIRST of the month 12 months ago, so the
--      earliest historical month is no longer a silently partial 16-day
--      sample.
--  [2] Uses bank_transaction.valueDate (proper date column) instead of
--      postingDate (text, requires cast). Value date is the conventional
--      basis for daily interest accrual under ACT/365 and the two
--      currently differ on 31 rows.
--  [3] carry CASE has an explicit ELSE 0 so accounts with NULL genre
--      (e.g. dp_account.type IS NULL) no longer silently yield NULL
--      dp_interest.
--  [4] Adds monthly_transactions (true monthly count). The original
--      end_of_month_transactions was the count on the LAST DAY of the
--      month only; preserved here as transactions_on_last_day.
--  [5] Adds is_partial_month / days_present_in_month so consumers can
--      tell whether the row covers a complete month.
--
-- Unchanged on purpose (semantic decisions for the firm to confirm):
--   * showOnPortal = true keeps the original filter. 262 NULL-flagged
--     transactions remain excluded. Change to
--     COALESCE("showOnPortal", false) = true if NULLs should be
--     treated as portal-visible.
--   * The `day <= '2024-02-29'` branch of the carry CASE remains for
--     historical re-runs even though it's unreachable on a 12-month
--     rolling window from today.
-- =====================================================================

WITH params AS (
    SELECT
        date_trunc('month', current_date - interval '12 months')::date AS series_start,  -- [1]
        (current_date - interval '1 day')::date                        AS series_end
),
calendar AS (
    SELECT d::date AS day
    FROM params,
         generate_series(params.series_start, params.series_end, interval '1 day') AS d
),
daily_summary AS (
    SELECT
        c.day,
        a.id AS account_id,
        pat.genre,
        COALESCE(SUM(CASE
            WHEN t."showOnPortal" = true
             AND t."valueDate" <= c.day                                                   -- [2]
            THEN t."amountValue" ELSE 0 END), 0) AS end_of_day_balance,
        COALESCE(SUM(CASE
            WHEN t."showOnPortal" = true
             AND t."valueDate" = c.day                                                    -- [2]
            THEN 1 ELSE 0 END), 0)               AS transactions_on_day,
        r.rate
    FROM dp_account AS a
    LEFT JOIN dp_account_type AS pat ON a.type = pat.id
    CROSS JOIN calendar c
    LEFT JOIN bank_transaction AS t ON t."dp_account" = a.id
    LEFT JOIN int_rates AS r        ON c.day BETWEEN r.date_start AND r.date_end
    GROUP BY c.day, a.id, pat.genre, r.rate
),
daily_interest AS (
    SELECT
        day, account_id, genre, end_of_day_balance, transactions_on_day, rate,
        (end_of_day_balance * (COALESCE(rate, 0) / 100) / 365) AS daily_interest,
        CASE
            WHEN genre = 'Deposit Accounts'                       THEN 0.10
            WHEN genre IN ('Escrow Accounts','Payment Accounts') THEN
                CASE
                    WHEN day <= DATE '2024-02-29' THEN 0.50
                    WHEN day >= DATE '2025-03-01' THEN 0.75
                    ELSE 0.50
                END
            ELSE 0                                                                        -- [3]
        END AS carry
    FROM daily_summary
),
monthly_aggregate AS (
    SELECT
        date_trunc('month', day)::date AS month_start,
        day, account_id, genre, end_of_day_balance, transactions_on_day,
        daily_interest, carry,
        SUM(daily_interest)      OVER w_month AS monthly_interest,
        SUM(transactions_on_day) OVER w_month AS monthly_transactions,                    -- [4]
        COUNT(*)                 OVER w_month AS days_present_in_month,                   -- [5]
        EXTRACT(DAY FROM
            (date_trunc('month', day) + interval '1 month - 1 day')
        )::int AS calendar_days_in_month,                                                 -- [5]
        ROW_NUMBER() OVER (
            PARTITION BY account_id, genre, date_trunc('month', day)
            ORDER BY day DESC
        ) AS rn
    FROM daily_interest
    WINDOW w_month AS (PARTITION BY account_id, genre, date_trunc('month', day))
)
SELECT
    CONCAT(month_start::text, '_', account_id) AS unique_id,
    month_start,
    account_id,
    genre,
    end_of_day_balance                         AS end_of_month_balance,
    transactions_on_day                        AS transactions_on_last_day,               -- [4]
    monthly_transactions,                                                                 -- [4]
    days_present_in_month,                                                                -- [5]
    calendar_days_in_month,                                                               -- [5]
    (days_present_in_month < calendar_days_in_month) AS is_partial_month,                 -- [5]
    monthly_interest,
    carry,
    (monthly_interest * carry) AS dp_interest
FROM monthly_aggregate
WHERE rn = 1
ORDER BY account_id, month_start;
