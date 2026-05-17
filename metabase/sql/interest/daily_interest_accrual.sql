-- =====================================================================
-- Daily interest accrual per dp_account x commercial bank x currency.
--
-- One row per (day, account, bank, currency) over the trailing 12
-- months. Same calculation chain as monthly_interest_accrual.sql but
-- without the monthly aggregation, so downstream consumers can pick
-- their own window (e.g. quarter for the commission plan).
--
-- Output columns
--   - day                        calendar date
--   - account_id                 dp_account.id
--   - bank                       commercial bank (bol / cb / fh / ...)
--   - currency                   account currency (from bank_account_sub)
--   - genre                      dp_account_type.genre
--   - day_count_basis            ACT/365 (GBP) or ACT/360 (USD, EUR)
--   - end_of_day_balance         running balance at end of day
--   - transactions_today         count of portal-visible txns on the day
--   - rate                       published central-bank rate, in %
--   - bank_currency_total        total settled funds at this bank in this
--                                currency on this day (used by the £/$/€40m
--                                ClearBank threshold)
--   - daily_interest             gross interest accrued on the day
--   - daily_carry                firm's share of the gross interest
--   - dp_interest                daily_interest * daily_carry
--
-- See metabase/sql/interest/monthly_interest_accrual.sql for the
-- full notes on join model, rate lookup, day-count conventions and the
-- per-bank carry rules. Both files share the same parameter CTEs
-- (currency_conventions, cb_rules); edit them in lockstep when
-- commercial terms change.
--
-- Source-query changes incorporated in this version
--   * Series start moved from "yesterday" (the prior version's
--     generate_series collapsed to a single day because the lower
--     bound was current_date - 1 day - 0 days) to the first of the
--     month 12 months ago.
--   * postingDate::date -> bank_transaction.valueDate (proper date
--     column, conventional basis for ACT/N interest accrual).
--   * carry CASE now has an explicit ELSE 0 so accounts with NULL
--     genre no longer silently produce NULL dp_interest.
--   * Multi-bank, multi-currency join model via bank_account_sub.
--   * int_rates lookup is scoped by currency to match the new
--     (bank, currency) keying of that table.
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
-- ClearBank carry rule parameters. Keep in sync with the monthly file.
cb_rules AS (
    SELECT * FROM (VALUES
      (DATE '2026-05-01', 'GBP', 75, 75, 50, 40000000::numeric),
      (DATE '2026-05-01', 'USD', 75, 75, 50, 40000000::numeric),
      (DATE '2026-05-01', 'EUR', 75, 75, 50, 40000000::numeric)
    ) AS r(effective_from, currency, min_central_bps, small_spread_bps, large_spread_bps, large_threshold)
),
-- Distinct (dp_account, bank, currency) triples. DISTINCT collapses
-- multiple subs at the same (bank, currency) for one account so
-- transactions are not double-counted. Legacy dp_accounts with no
-- sub default to (bol, dp_account.currency or GBP).
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
            THEN 1 ELSE 0 END), 0)               AS transactions_today,
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
-- Daily aggregate at each (bank, currency); fuels the ClearBank £/$/€40m threshold.
daily_bank_total AS (
    SELECT day, bank, currency, SUM(end_of_day_balance) AS bank_currency_total
    FROM daily_summary
    GROUP BY day, bank, currency
),
daily_interest AS (
    SELECT
        ds.day, ds.account_id, ds.bank, ds.currency, ds.genre, ds.day_count_basis,
        ds.end_of_day_balance, ds.transactions_today, ds.rate,
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
            -- ClearBank - GBP / USD / EUR per cb_rules
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
)
SELECT
    day,
    account_id,
    bank,
    currency,
    genre,
    day_count_basis,
    end_of_day_balance,
    transactions_today,
    rate,
    bank_currency_total,
    daily_interest,
    daily_carry,
    (daily_interest * daily_carry) AS dp_interest
FROM daily_interest
ORDER BY account_id, bank, currency, day;
