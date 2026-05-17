-- =====================================================================
-- Monthly interest accrual per dp_account x commercial bank x currency.
--
-- Produces one row per (account, bank, currency, month) for the
-- trailing 12 months, containing:
--   - bank                       commercial bank (bol / cb / fh / ...)
--   - currency                   account currency (from bank_account_sub)
--   - end_of_month_balance       running balance at the last day in scope
--   - transactions_on_last_day   count of portal-visible txns on that day
--   - monthly_transactions       count of portal-visible txns over the month
--   - days_present_in_month      how many days of the month are in scope
--   - calendar_days_in_month     total days in the calendar month
--   - is_partial_month           TRUE if the row covers less than the full month
--   - day_count_basis            ACT/365 (GBP) or ACT/360 (USD, EUR)
--   - monthly_interest           gross client interest accrued in the month
--   - effective_carry            interest-weighted average of daily_carry for the month
--   - dp_interest                firm's share = SUM(daily_interest * daily_carry)
--
-- Grain of the source data
-- ------------------------
-- A dp_account can have one or more bank_account_sub rows, potentially
-- at different commercial banks and/or different currencies. The join
-- is therefore bank_account_sub.dp_account -> dp_account.id. Distinct
-- (account, bank, currency) triples become the natural grain. Legacy
-- dp_accounts that have no sub default to (bol, dp_account.currency or
-- 'GBP') so behaviour is unchanged for the 7 historical rows in that
-- state. When a dp_account has multiple subs at the same (bank,
-- currency), the DISTINCT in account_bank_currencies collapses them so
-- transactions are not double-counted.
--
-- Rates and day-count conventions
-- -------------------------------
-- int_rates is now keyed by (bank, currency) where bank is the
-- CENTRAL bank that publishes the rate (boe / fed / ecb), not the
-- commercial bank. Lookup happens by currency: one published rate per
-- currency per day. Day-count basis follows the market convention for
-- that currency:
--     GBP  ACT/365   (BoE convention)
--     USD  ACT/360   (Fed convention)
--     EUR  ACT/360   (ECB convention)
-- Encoded in currency_conventions; unknown currencies default to 365.
--
-- Carry per commercial bank
-- -------------------------
-- carry = firm's share of the gross central-bank interest paid.
-- Computed per day because ClearBank's carry depends on the daily
-- aggregate balance held in that currency. The shortcut
-- monthly_interest * carry no longer holds in general; the canonical
-- definition is dp_interest = SUM(daily_interest * daily_carry).
--
-- bol (Bank of London) - unchanged from prior version; GBP only:
--     Deposit Accounts                     -> 0.10
--     Escrow / Payment Accounts:
--         day <= 2024-02-29                -> 0.50  (historical)
--         day >= 2025-03-01                -> 0.75
--         otherwise                        -> 0.50
--
-- cb (ClearBank) - effective 2026-05-01. Same shape for GBP, USD, EUR:
--     Where the published central-bank rate (in basis points, "A") is
--     greater than 75 bps, daily firm interest is:
--         (A - 75) / B * C / 10000   if total settled < 40m in currency
--         (A - 50) / B * C / 10000   otherwise
--     where C is the total settled funds at ClearBank in that
--     currency at end of day, and B is the day-count basis from
--     currency_conventions. Expressed as a carry on the gross interest
--     at A, that's (A - 75)/A or (A - 50)/A. Zero when the published
--     rate is at or below 75 bps, or before the effective date.
--     Threshold per currency: £40m / $40m / €40m. Edit cb_rules to
--     adjust commercial terms.
--
-- fh (Federated Hermes) - no rule supplied yet, carry = 0.
--
-- Unchanged on purpose
-- --------------------
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
-- Day-count basis per currency for ACT/N interest calculations.
currency_conventions AS (
    SELECT 'GBP'::text AS currency, 365::int AS day_count_basis UNION ALL
    SELECT 'USD',                   360                          UNION ALL
    SELECT 'EUR',                   360
),
-- ClearBank carry rule parameters. Edit values to track commercial terms.
cb_rules AS (
    SELECT * FROM (VALUES
      (DATE '2026-05-01', 'GBP', 75, 75, 50, 40000000::numeric),
      (DATE '2026-05-01', 'USD', 75, 75, 50, 40000000::numeric),
      (DATE '2026-05-01', 'EUR', 75, 75, 50, 40000000::numeric)
    ) AS r(effective_from, currency, min_central_bps, small_spread_bps, large_spread_bps, large_threshold)
),
-- Distinct (dp_account, bank, currency) triples. One row per triple
-- regardless of how many subs a dp_account has at that (bank, currency).
-- dp_accounts with no sub default to (bol, dp_account.currency or GBP).
account_bank_currencies AS (
    SELECT DISTINCT
        a.id                                        AS account_id,
        COALESCE(b.bank, 'bol')                     AS bank,
        COALESCE(b.currency, a.currency, 'GBP')     AS currency
    FROM dp_account a
    LEFT JOIN (
        SELECT dp_account, bank, currency
        FROM bank_account_sub
        WHERE bank IS NOT NULL
    ) b ON b.dp_account = a.id
),
daily_summary AS (
    SELECT
        c.day,
        ab.account_id,
        ab.bank,
        ab.currency,
        pat.genre,
        COALESCE(SUM(CASE
            WHEN t."showOnPortal" = true
             AND t."valueDate" <= c.day
             AND COALESCE(t.bank, 'bol') = ab.bank
             AND COALESCE(t."accountCurrency", t.currency, ab.currency) = ab.currency
            THEN t."amountValue" ELSE 0 END), 0) AS end_of_day_balance,
        COALESCE(SUM(CASE
            WHEN t."showOnPortal" = true
             AND t."valueDate" = c.day
             AND COALESCE(t.bank, 'bol') = ab.bank
             AND COALESCE(t."accountCurrency", t.currency, ab.currency) = ab.currency
            THEN 1 ELSE 0 END), 0)               AS transactions_on_day,
        r.rate,
        COALESCE(cc.day_count_basis, 365) AS day_count_basis
    FROM account_bank_currencies ab
    JOIN dp_account a               ON a.id = ab.account_id
    LEFT JOIN dp_account_type pat   ON a.type = pat.id
    CROSS JOIN calendar c
    LEFT JOIN bank_transaction t    ON t."dp_account" = ab.account_id
    LEFT JOIN int_rates r           ON c.day BETWEEN r.date_start AND r.date_end
                                   AND r.currency = ab.currency
    LEFT JOIN currency_conventions cc ON cc.currency = ab.currency
    GROUP BY c.day, ab.account_id, ab.bank, ab.currency, pat.genre, r.rate, cc.day_count_basis
),
-- Daily aggregate at each (bank, currency), used by ClearBank's £/$/€40m threshold.
daily_bank_total AS (
    SELECT day, bank, currency, SUM(end_of_day_balance) AS bank_currency_total
    FROM daily_summary
    GROUP BY day, bank, currency
),
daily_interest AS (
    SELECT
        ds.day, ds.account_id, ds.currency, ds.genre, ds.bank,
        ds.end_of_day_balance, ds.transactions_on_day, ds.rate, ds.day_count_basis,
        dbt.bank_currency_total,
        (ds.end_of_day_balance * COALESCE(ds.rate, 0) / 100 / ds.day_count_basis) AS daily_interest,
        CASE
            -- Bank of London - GBP only, legacy logic
            WHEN ds.bank = 'bol' AND ds.currency = 'GBP' THEN
                CASE
                    WHEN ds.genre = 'Deposit Accounts'                       THEN 0.10
                    WHEN ds.genre IN ('Escrow Accounts','Payment Accounts') THEN
                        CASE
                            WHEN ds.day <= DATE '2024-02-29' THEN 0.50
                            WHEN ds.day >= DATE '2025-03-01' THEN 0.75
                            ELSE 0.50
                        END
                    ELSE 0
                END
            -- ClearBank - GBP / USD / EUR per cb_rules. Same shape per
            -- currency; threshold and rate basis vary.
            WHEN ds.bank = 'cb' THEN
                COALESCE((
                    SELECT CASE
                        WHEN ds.day < cr.effective_from                                   THEN 0
                        WHEN (COALESCE(ds.rate, 0) * 100) <= cr.min_central_bps           THEN 0
                        WHEN COALESCE(dbt.bank_currency_total, 0) < cr.large_threshold
                            THEN ((COALESCE(ds.rate, 0) * 100) - cr.small_spread_bps)
                                  / NULLIF((COALESCE(ds.rate, 0) * 100), 0)
                        ELSE ((COALESCE(ds.rate, 0) * 100) - cr.large_spread_bps)
                              / NULLIF((COALESCE(ds.rate, 0) * 100), 0)
                    END
                    FROM cb_rules cr
                    WHERE cr.currency = ds.currency
                ), 0)
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
        day, account_id, currency, genre, bank, day_count_basis,
        end_of_day_balance, transactions_on_day, daily_interest, daily_carry,
        SUM(daily_interest)                  OVER w_month AS monthly_interest,
        SUM(daily_interest * daily_carry)    OVER w_month AS monthly_dp_interest,
        SUM(transactions_on_day)             OVER w_month AS monthly_transactions,
        COUNT(*)                             OVER w_month AS days_present_in_month,
        EXTRACT(DAY FROM
            (date_trunc('month', day) + interval '1 month - 1 day')
        )::int AS calendar_days_in_month,
        ROW_NUMBER() OVER (
            PARTITION BY account_id, genre, bank, currency, date_trunc('month', day)
            ORDER BY day DESC
        ) AS rn
    FROM daily_interest
    WINDOW w_month AS (PARTITION BY account_id, genre, bank, currency, date_trunc('month', day))
)
SELECT
    CONCAT(month_start::text, '_', account_id, '_', bank, '_', currency) AS unique_id,
    month_start,
    account_id,
    bank,
    currency,
    genre,
    day_count_basis,
    end_of_day_balance                                              AS end_of_month_balance,
    transactions_on_day                                             AS transactions_on_last_day,
    monthly_transactions,
    days_present_in_month,
    calendar_days_in_month,
    (days_present_in_month < calendar_days_in_month)                AS is_partial_month,
    monthly_interest,
    -- Interest-weighted average carry: equivalent to the prior "carry"
    -- column when carry is constant across the month.
    CASE WHEN monthly_interest = 0 THEN NULL
         ELSE monthly_dp_interest / monthly_interest
    END                                                             AS effective_carry,
    monthly_dp_interest                                             AS dp_interest
FROM monthly_aggregate
WHERE rn = 1
ORDER BY account_id, bank, currency, month_start;
