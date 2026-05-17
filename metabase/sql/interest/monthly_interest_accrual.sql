-- =====================================================================
-- Monthly interest accrual per dp_account, with per-bank carry.
--
-- Produces one row per (account, month) for the trailing 12 months,
-- containing:
--   - bank                       bank holding the account (resolved via
--                                dp_account.bank_account_id ->
--                                bank_account_sub.bank, default 'bol')
--   - end_of_month_balance       running balance at the last day in scope
--   - transactions_on_last_day   count of portal-visible txns on that day
--   - monthly_transactions       count of portal-visible txns over the month
--   - days_present_in_month      how many days of the month are in scope
--   - calendar_days_in_month     total days in the calendar month
--   - is_partial_month           TRUE if the row covers less than the full month
--   - monthly_interest           gross client interest accrued in the month (ACT/365)
--   - effective_carry            interest-weighted average of daily_carry for the month
--   - dp_interest                firm's share = SUM(daily_interest * daily_carry)
--
-- Carry = the firm's share of the gross BoE interest paid. Computed
-- per day because ClearBank's carry depends on the daily aggregate
-- balance held at ClearBank. The previous monthly_interest * carry
-- shortcut still works for BoL (carry constant within each month) but
-- not for cb in general, so the canonical definition is now
-- dp_interest = SUM(daily_interest * daily_carry).
--
-- Per-bank carry rules
-- --------------------
-- bol (Bank of London) - unchanged from prior version:
--     Deposit Accounts                     -> 0.10
--     Escrow / Payment Accounts:
--         day <= 2024-02-29                -> 0.50  (historical)
--         day >= 2025-03-01                -> 0.75
--         otherwise (2024-03-01..2025-02-28) -> 0.50
--
-- cb (ClearBank) - effective 1 May 2026, GBP only:
--     Where the published BoE base rate (in basis points, "A") is
--     greater than 75 bps, daily firm interest is:
--         (A - 75) / 365 * C / 10000   if total settled GBP < £40,000,000
--         (A - 50) / 365 * C / 10000   otherwise
--     where C = total settled funds in all cb GBP accounts at end of
--     day. Expressed as a carry on the gross interest computed at A,
--     that's (A - 75) / A or (A - 50) / A. Zero when BoE <= 75 bps or
--     currency is not GBP or day is before 1 May 2026. Adjust the
--     thresholds and effective date in the cb_rules CTE if the terms
--     change.
--
-- fh (Federated Hermes) - no rule supplied yet, carry = 0.
--
-- Unknown / unlinked accounts default to bol so that the 8 legacy
-- dp_account rows without a bank_account_id link continue to behave
-- exactly as they did before the multi-bank migration. Backfill
-- bank_account_id on those rows when convenient.
--
-- Unchanged on purpose (semantic decisions for the firm to confirm):
--   * showOnPortal = true keeps the original filter. 262 NULL-flagged
--     transactions remain excluded. Change to
--     COALESCE("showOnPortal", false) = true if NULLs should be
--     treated as portal-visible.
-- =====================================================================

WITH params AS (
    SELECT
        date_trunc('month', current_date - interval '12 months')::date AS series_start,
        (current_date - interval '1 day')::date                        AS series_end
),
calendar AS (
    SELECT d::date AS day
    FROM params,
         generate_series(params.series_start, params.series_end, interval '1 day') AS d
),
-- ClearBank rule parameters. Edit here when commercial terms change.
cb_rules AS (
    SELECT
        DATE '2026-05-01'  AS effective_from,
        75                 AS min_boe_bps,
        75                 AS small_balance_spread_bps,
        50                 AS large_balance_spread_bps,
        40000000::numeric  AS large_balance_threshold,
        'GBP'              AS applicable_currency
),
daily_summary AS (
    SELECT
        c.day,
        a.id AS account_id,
        a.currency,
        pat.genre,
        COALESCE(bas.bank, 'bol') AS bank,                                                -- multi-bank: resolve via sub-account
        COALESCE(SUM(CASE
            WHEN t."showOnPortal" = true AND t."valueDate" <= c.day
            THEN t."amountValue" ELSE 0 END), 0) AS end_of_day_balance,
        COALESCE(SUM(CASE
            WHEN t."showOnPortal" = true AND t."valueDate" = c.day
            THEN 1 ELSE 0 END), 0)               AS transactions_on_day,
        r.rate
    FROM dp_account AS a
    LEFT JOIN dp_account_type AS pat   ON a.type = pat.id
    LEFT JOIN bank_account_sub AS bas  ON bas.id = a.bank_account_id
    CROSS JOIN calendar c
    LEFT JOIN bank_transaction AS t    ON t."dp_account" = a.id
    LEFT JOIN int_rates AS r           ON c.day BETWEEN r.date_start AND r.date_end
    GROUP BY c.day, a.id, a.currency, pat.genre, bas.bank, r.rate
),
-- Daily aggregate held at each bank per currency, used by the cb
-- £40m threshold and any future bank rules that key off balance bands.
daily_bank_total AS (
    SELECT day, bank, currency, SUM(end_of_day_balance) AS bank_currency_total
    FROM daily_summary
    GROUP BY day, bank, currency
),
daily_interest AS (
    SELECT
        ds.day, ds.account_id, ds.currency, ds.genre, ds.bank,
        ds.end_of_day_balance, ds.transactions_on_day, ds.rate,
        dbt.bank_currency_total,
        (ds.end_of_day_balance * COALESCE(ds.rate, 0) / 100 / 365) AS daily_interest,
        CASE
            -- Bank of London (legacy default, unchanged)
            WHEN ds.bank = 'bol' THEN
                CASE
                    WHEN ds.genre = 'Deposit Accounts'                    THEN 0.10
                    WHEN ds.genre IN ('Escrow Accounts','Payment Accounts') THEN
                        CASE
                            WHEN ds.day <= DATE '2024-02-29' THEN 0.50
                            WHEN ds.day >= DATE '2025-03-01' THEN 0.75
                            ELSE 0.50
                        END
                    ELSE 0
                END
            -- ClearBank (from 2026-05-01, GBP only, BoE > 75 bps)
            WHEN ds.bank = 'cb' THEN
                CASE
                    WHEN ds.day < (SELECT effective_from FROM cb_rules)            THEN 0
                    WHEN ds.currency <> (SELECT applicable_currency FROM cb_rules) THEN 0
                    WHEN (COALESCE(ds.rate, 0) * 100)
                         <= (SELECT min_boe_bps FROM cb_rules)                     THEN 0
                    WHEN COALESCE(dbt.bank_currency_total, 0)
                         < (SELECT large_balance_threshold FROM cb_rules) THEN
                        ((COALESCE(ds.rate, 0) * 100)
                         - (SELECT small_balance_spread_bps FROM cb_rules))
                          / NULLIF((COALESCE(ds.rate, 0) * 100), 0)
                    ELSE
                        ((COALESCE(ds.rate, 0) * 100)
                         - (SELECT large_balance_spread_bps FROM cb_rules))
                          / NULLIF((COALESCE(ds.rate, 0) * 100), 0)
                END
            -- Federated Hermes - no rule supplied yet
            WHEN ds.bank = 'fh' THEN 0
            ELSE 0
        END AS daily_carry
    FROM daily_summary ds
    LEFT JOIN daily_bank_total dbt
      ON dbt.day = ds.day AND dbt.bank = ds.bank AND dbt.currency = ds.currency
),
monthly_aggregate AS (
    SELECT
        date_trunc('month', day)::date AS month_start,
        day, account_id, currency, genre, bank,
        end_of_day_balance, transactions_on_day, daily_interest, daily_carry,
        SUM(daily_interest)                       OVER w_month AS monthly_interest,
        SUM(daily_interest * daily_carry)         OVER w_month AS monthly_dp_interest,
        SUM(transactions_on_day)                  OVER w_month AS monthly_transactions,
        COUNT(*)                                  OVER w_month AS days_present_in_month,
        EXTRACT(DAY FROM
            (date_trunc('month', day) + interval '1 month - 1 day')
        )::int AS calendar_days_in_month,
        ROW_NUMBER() OVER (
            PARTITION BY account_id, genre, bank, date_trunc('month', day)
            ORDER BY day DESC
        ) AS rn
    FROM daily_interest
    WINDOW w_month AS (PARTITION BY account_id, genre, bank, date_trunc('month', day))
)
SELECT
    CONCAT(month_start::text, '_', account_id) AS unique_id,
    month_start,
    account_id,
    bank,
    currency,
    genre,
    end_of_day_balance                                              AS end_of_month_balance,
    transactions_on_day                                             AS transactions_on_last_day,
    monthly_transactions,
    days_present_in_month,
    calendar_days_in_month,
    (days_present_in_month < calendar_days_in_month)                AS is_partial_month,
    monthly_interest,
    -- Interest-weighted average carry: useful for reporting,
    -- equivalent to the prior "carry" column when carry is constant
    -- across the month.
    CASE WHEN monthly_interest = 0 THEN NULL
         ELSE monthly_dp_interest / monthly_interest
    END                                                             AS effective_carry,
    monthly_dp_interest                                             AS dp_interest
FROM monthly_aggregate
WHERE rn = 1
ORDER BY account_id, month_start;
