-- =====================================================================
-- Quarterly interest accrual per dp_account x commercial bank x currency.
--
-- Populates / refreshes int_quarterly. Produces one row per
-- (account, bank, currency, quarter) for the trailing 12 months,
-- with the firm's share computed at daily grain (because ClearBank
-- carry depends on the daily aggregate balance) and then summed to
-- the quarter.
--
-- Output columns
--   - unique_id                  CONCAT(quarter_end, account_id, bank, currency)
--   - quarter_start, quarter_end as-defined by the bucket math below
--   - payable                    last day of the second month after quarter_end
--   - account_id                 dp_account.id
--   - bank                       commercial bank (bol / cb / fh / ...)
--   - currency                   account currency (from bank_account_sub)
--   - genre                      dp_account_type.genre
--   - dp_introduced/managing/supervising  attribution columns from dp_account
--   - end_of_quarter_balance     running balance at the last day in scope
--   - end_of_quarter_transactions count of portal-visible txns on that last day
--   - quarterly_transactions     count of portal-visible txns over the bucket
--   - days_present_in_quarter, calendar_days_in_quarter, is_partial_quarter
--   - quarterly_interest         gross interest accrued in the bucket
--   - effective_carry            interest-weighted average of daily_carry
--   - dp_interest                firm's share = SUM(daily_interest * daily_carry)
--
-- IMPORTANT - quarter-bucket labels
-- ---------------------------------
-- The bucketing expression DATE_TRUNC('quarter', day + interval '1 month')
-- groups days into three-month windows that ARE NOT the calendar
-- quarters that quarter_start / quarter_end name. The bucket key
-- for a date d is the start of the calendar quarter containing
-- d + 1 month, which means each bucket contains the LAST month of
-- one calendar quarter plus the first two months of the next. So:
--
--    Days in Mar/Apr/May  ->  bucket labelled quarter_end = Mar 31
--    Days in Jun/Jul/Aug  ->  bucket labelled quarter_end = Jun 30
--    Days in Sep/Oct/Nov  ->  bucket labelled quarter_end = Sep 30
--    Days in Dec/Jan/Feb  ->  bucket labelled quarter_end = Dec 31
--
-- The labels (quarter_start, quarter_end) point at the calendar
-- quarter immediately BEFORE the bucket's membership. This matches
-- the existing int_quarterly rows in production, so the behaviour
-- is preserved here. If the labelling is ever revisited, swap to
-- `DATE_TRUNC('quarter', day)` and recompute quarter_end as
-- bucket_key + interval '3 months - 1 day'.
--
-- See metabase/sql/interest/monthly_interest_accrual.sql for the
-- full notes on join model, rate lookup, day-count conventions and
-- the per-bank carry rules. The three interest files share the same
-- parameter CTEs (currency_conventions, cb_rules); edit them in
-- lockstep when commercial terms change.
--
-- Source-query changes incorporated in this version
--   * postingDate::date -> bank_transaction.valueDate.
--   * carry CASE has an explicit ELSE 0.
--   * Multi-bank / multi-currency join via bank_account_sub.dp_account.
--   * int_rates lookup scoped by currency.
--   * Day-count basis ACT/365 (GBP) or ACT/360 (USD, EUR).
--   * Per-bank carry: bol GBP unchanged; cb GBP/USD/EUR per cb_rules;
--     fh = 0.
--   * Series start extended back so the earliest bucket is complete
--     (per the membership-end of the bucket containing 12 months ago).
--     The previous version started 12 months ago and could leave the
--     leading bucket partial; is_partial_quarter now flags any bucket
--     where the data does not cover the full three months.
-- =====================================================================

WITH params AS (
    -- series_start: start of the membership range of the bucket that
    -- contains "12 months ago" so the leading bucket is complete.
    SELECT
        (DATE_TRUNC('quarter', (current_date - interval '12 months') + interval '1 month')
            - interval '1 month')::date                              AS series_start,
        (current_date - interval '1 day')::date                      AS series_end
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
-- ClearBank carry rule parameters. Keep in sync with the daily and monthly files.
cb_rules AS (
    SELECT * FROM (VALUES
      (DATE '2026-05-01', 'GBP', 75, 75, 50, 40000000::numeric),
      (DATE '2026-05-01', 'USD', 75, 75, 50, 40000000::numeric),
      (DATE '2026-05-01', 'EUR', 75, 75, 50, 40000000::numeric)
    ) AS r(effective_from, currency, min_central_bps, small_spread_bps, large_spread_bps, large_threshold)
),
-- Distinct (dp_account, bank, currency) triples. DISTINCT collapses
-- multiple subs at the same (bank, currency) for one account.
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
        a.dp_introduced,
        a.dp_managing,
        a.dp_supervising,
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
    GROUP BY c.day, ab.account_id, ab.bank, ab.currency, pat.genre,
             a.dp_introduced, a.dp_managing, a.dp_supervising,
             r.rate, cc.day_count_basis
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
        ds.dp_introduced, ds.dp_managing, ds.dp_supervising,
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
),
quarterly_aggregate AS (
    SELECT
        (DATE_TRUNC('quarter', day + interval '1 month') - interval '3 months')::date AS quarter_start,
        (DATE_TRUNC('quarter', day + interval '1 month') - interval '1 day')::date    AS quarter_end,
        (DATE_TRUNC('quarter', day + interval '1 month') + interval '2 months' - interval '1 day')::date AS payable,
        day, account_id, bank, currency, genre,
        dp_introduced, dp_managing, dp_supervising,
        end_of_day_balance, transactions_today, daily_interest, daily_carry,
        SUM(daily_interest)                  OVER w_q AS quarterly_interest,
        SUM(daily_interest * daily_carry)    OVER w_q AS quarterly_dp_interest,
        SUM(transactions_today)              OVER w_q AS quarterly_transactions,
        COUNT(*)                             OVER w_q AS days_present_in_quarter,
        -- Calendar days in the bucket's MEMBERSHIP range (the three
        -- months that actually contribute), not in the label range.
        ((DATE_TRUNC('quarter', day + interval '1 month') + interval '2 months')::date
            - (DATE_TRUNC('quarter', day + interval '1 month') - interval '1 month')::date) AS calendar_days_in_quarter,
        ROW_NUMBER() OVER (
            PARTITION BY account_id, genre, bank, currency, DATE_TRUNC('quarter', day + interval '1 month')
            ORDER BY day DESC
        ) AS rn
    FROM daily_interest
    WINDOW w_q AS (
        PARTITION BY account_id, genre, bank, currency, DATE_TRUNC('quarter', day + interval '1 month')
    )
)
SELECT
    CONCAT(quarter_end::text, '_', account_id, '_', bank, '_', currency) AS unique_id,
    quarter_start,
    quarter_end,
    payable,
    account_id,
    bank,
    currency,
    genre,
    dp_introduced,
    dp_managing,
    dp_supervising,
    end_of_day_balance                            AS end_of_quarter_balance,
    transactions_today                            AS end_of_quarter_transactions,
    quarterly_transactions,
    days_present_in_quarter,
    calendar_days_in_quarter,
    (days_present_in_quarter < calendar_days_in_quarter) AS is_partial_quarter,
    quarterly_interest,
    -- Interest-weighted average carry: equivalent to the prior "carry"
    -- column when carry is constant across the quarter.
    CASE WHEN quarterly_interest = 0 THEN NULL
         ELSE quarterly_dp_interest / quarterly_interest
    END                                           AS effective_carry,
    quarterly_dp_interest                         AS dp_interest
FROM quarterly_aggregate
WHERE rn = 1
ORDER BY account_id, bank, currency, quarter_end;
