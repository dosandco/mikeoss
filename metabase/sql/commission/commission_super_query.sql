-- =====================================================================
-- Commission super-query.
--
-- Single SELECT at one row per (month, dp_account, role, staff) that
-- exposes everything needed to build commission summary tables by
-- aggregation. Designed to be the only source the dashboard queries
-- against.
--
-- The model
-- ---------
-- For each (month, dp_account):
--   * fees     = SUM(fees_transactions.net_amount) on that account, that month
--   * interest = monthly_interest * carry, where:
--                  - monthly_interest is read from int_monthly
--                    (populated by the official monthly_interest_accrual
--                    query; treated here as gross client interest)
--                  - carry is the firm's share of gross interest, by
--                    (bank, currency, genre, date). Today all production
--                    data is bol/GBP, so the carry rules are inlined for
--                    that case. When ClearBank/Federated Hermes go live
--                    OR int_monthly is enriched with a dp_interest
--                    column, simplify the monthly_interest CTE below to
--                    read it directly.
--
-- The dp_account row tells us who fills each attribution slot:
--   * dp_introduced    -> 'brought_in' role
--   * dp_managing      -> 'managed' role
--   * dp_supervising   -> 'supervised' role
--   * ext_introducer   -> 'introducer' role
--
-- sys_commission_users gives each staff member:
--   * one rate per role (brought_in, managed, supervised, introducer)
--   * a commission_multiple
--   * a quarterly min_threshold
--   * introducer_months (caps the introducer's earning window)
--
-- The final commission on a row is simply:
--   (fees + interest) * row_rate * row_multiple
--
-- where row_rate is the staff member's rate for the row's role.
--
-- Period dimensions
-- -----------------
-- Output is at month grain. Each row carries:
--   * month_start, month_end
--   * plan_fy_year, plan_quarter_num, plan_quarter_label,
--     plan_quarter_start, plan_quarter_end, plan_payable_date
-- per the DOS commission plan (FY ending 30 Nov; quarters end
-- 28 Feb, 30 May, 31 Aug, 30 Nov; paid in the second calendar month
-- following). Calendar quarters are not exposed - the plan's
-- fiscal quarters are what the dashboard cares about.
-- =====================================================================

WITH params AS (
    SELECT DATE '2024-07-01'                       AS plan_effective_from,
           date_trunc('month', current_date)::date AS through_month
),
months AS (
    SELECT m::date AS month_start
    FROM params,
         generate_series(plan_effective_from, through_month, interval '1 month') AS m
),
-- Monthly fees per account, gross of carry, net of VAT (= net_amount).
monthly_fees AS (
    SELECT
        date_trunc('month', date::date)::date AS month_start,
        dp_account                            AS account_id,
        SUM(net_amount)                       AS fees
    FROM fees_transactions
    WHERE date IS NOT NULL
      AND account_type = 'SALES'
      AND dp_account IS NOT NULL
    GROUP BY 1, 2
),
-- Monthly interest per account, after carry.
--
-- int_monthly currently has duplicate rows per (month, account) from
-- the pre/post multi-bank refactor; DISTINCT ON keeps the most recent.
-- Carry is the BoL GBP rule by genre and date; this matches every
-- account in production today. When ClearBank/FH go live, replace
-- the inline CASE with a join to the bank/currency/date carry rules
-- already in the official interest accrual queries.
monthly_interest AS (
    SELECT DISTINCT ON (im.month_start, im.dp_account)
        im.month_start::date                  AS month_start,
        a.id                                  AS account_id,
        COALESCE(im.monthly_interest, 0)      AS interest_gross,
        COALESCE(im.monthly_interest, 0)
          * CASE pat.genre
              WHEN 'Deposit Accounts'  THEN 0.10
              WHEN 'Escrow Accounts'   THEN
                  CASE WHEN im.month_start >= DATE '2025-03-01' THEN 0.75 ELSE 0.50 END
              WHEN 'Payment Accounts'  THEN
                  CASE WHEN im.month_start >= DATE '2025-03-01' THEN 0.75 ELSE 0.50 END
              ELSE 0
            END                               AS interest_firm
    FROM int_monthly im
    JOIN dp_account a            ON a.id::text = im.dp_account
    LEFT JOIN dp_account_type pat ON a.type = pat.id
    ORDER BY im.month_start, im.dp_account, im.created_at DESC
),
-- One row per (month, account) with attribution emails and both bases.
account_month AS (
    SELECT
        m.month_start,
        a.id                                       AS account_id,
        a.title                                    AS account_title,
        a.currency                                 AS currency,
        a.created_at::date                         AS account_opened,
        pat.genre                                  AS genre,
        (SELECT bank FROM bank_account_sub
          WHERE dp_account = a.id LIMIT 1)         AS bank,
        a.dp_introduced                            AS staff_introduced,
        a.dp_managing                              AS staff_managing,
        a.dp_supervising                           AS staff_supervising,
        a.ext_introducer                           AS staff_introducer,
        COALESCE(mf.fees, 0)                       AS fees,
        COALESCE(mi.interest_firm, 0)              AS interest
    FROM months m
    CROSS JOIN dp_account a
    LEFT JOIN dp_account_type pat ON a.type = pat.id
    LEFT JOIN monthly_fees      mf ON mf.month_start = m.month_start AND mf.account_id = a.id
    LEFT JOIN monthly_interest  mi ON mi.month_start = m.month_start AND mi.account_id = a.id
),
-- Explode into one row per attributed role.
exploded AS (
    SELECT month_start, account_id, account_title, bank, currency, genre, account_opened,
           'brought_in'::text AS role, staff_introduced  AS staff_email, fees, interest
    FROM account_month WHERE staff_introduced IS NOT NULL

    UNION ALL
    SELECT month_start, account_id, account_title, bank, currency, genre, account_opened,
           'managed', staff_managing, fees, interest
    FROM account_month WHERE staff_managing IS NOT NULL

    UNION ALL
    SELECT month_start, account_id, account_title, bank, currency, genre, account_opened,
           'supervised', staff_supervising, fees, interest
    FROM account_month WHERE staff_supervising IS NOT NULL

    UNION ALL
    SELECT month_start, account_id, account_title, bank, currency, genre, account_opened,
           'introducer', staff_introducer, fees, interest
    FROM account_month WHERE staff_introducer IS NOT NULL
)
SELECT
    -- Period dimensions
    e.month_start,
    (e.month_start + interval '1 month - 1 day')::date                         AS month_end,
    TO_CHAR(e.month_start, 'YYYY-MM')                                          AS month_label,

    -- DOS plan quarter (FY ending 30 Nov; Q1 ends 28 Feb)
    CASE WHEN EXTRACT(MONTH FROM e.month_start) = 12
         THEN EXTRACT(YEAR FROM e.month_start)::int + 1
         ELSE EXTRACT(YEAR FROM e.month_start)::int
    END                                                                        AS plan_fy_year,
    CASE WHEN EXTRACT(MONTH FROM e.month_start) IN (12, 1, 2) THEN 1
         WHEN EXTRACT(MONTH FROM e.month_start) IN (3, 4, 5)  THEN 2
         WHEN EXTRACT(MONTH FROM e.month_start) IN (6, 7, 8)  THEN 3
         ELSE 4
    END                                                                        AS plan_quarter_num,
    'FY' || (CASE WHEN EXTRACT(MONTH FROM e.month_start) = 12
                  THEN EXTRACT(YEAR FROM e.month_start)::int + 1
                  ELSE EXTRACT(YEAR FROM e.month_start)::int END)
         || '-Q' || (CASE WHEN EXTRACT(MONTH FROM e.month_start) IN (12,1,2) THEN 1
                          WHEN EXTRACT(MONTH FROM e.month_start) IN (3,4,5)  THEN 2
                          WHEN EXTRACT(MONTH FROM e.month_start) IN (6,7,8)  THEN 3
                          ELSE 4 END)                                          AS plan_quarter_label,
    CASE WHEN EXTRACT(MONTH FROM e.month_start) IN (12,1,2)
            THEN make_date(CASE WHEN EXTRACT(MONTH FROM e.month_start) = 12
                                THEN EXTRACT(YEAR FROM e.month_start)::int
                                ELSE EXTRACT(YEAR FROM e.month_start)::int - 1 END,
                           12, 1)
         WHEN EXTRACT(MONTH FROM e.month_start) IN (3,4,5)  THEN make_date(EXTRACT(YEAR FROM e.month_start)::int,  3, 1)
         WHEN EXTRACT(MONTH FROM e.month_start) IN (6,7,8)  THEN make_date(EXTRACT(YEAR FROM e.month_start)::int,  6, 1)
         ELSE                                                    make_date(EXTRACT(YEAR FROM e.month_start)::int,  9, 1)
    END                                                                        AS plan_quarter_start,
    CASE WHEN EXTRACT(MONTH FROM e.month_start) IN (12,1,2)
            THEN (make_date(CASE WHEN EXTRACT(MONTH FROM e.month_start) = 12
                                 THEN EXTRACT(YEAR FROM e.month_start)::int + 1
                                 ELSE EXTRACT(YEAR FROM e.month_start)::int END,
                            3, 1) - interval '1 day')::date
         WHEN EXTRACT(MONTH FROM e.month_start) IN (3,4,5)  THEN make_date(EXTRACT(YEAR FROM e.month_start)::int,  5, 30)
         WHEN EXTRACT(MONTH FROM e.month_start) IN (6,7,8)  THEN make_date(EXTRACT(YEAR FROM e.month_start)::int,  8, 31)
         ELSE                                                    make_date(EXTRACT(YEAR FROM e.month_start)::int, 11, 30)
    END                                                                        AS plan_quarter_end,
    -- Payable on the usual payroll date in the second month after quarter end
    CASE WHEN EXTRACT(MONTH FROM e.month_start) IN (12,1,2)
            THEN make_date(CASE WHEN EXTRACT(MONTH FROM e.month_start) = 12
                                THEN EXTRACT(YEAR FROM e.month_start)::int + 1
                                ELSE EXTRACT(YEAR FROM e.month_start)::int END,
                           4, 28)
         WHEN EXTRACT(MONTH FROM e.month_start) IN (3,4,5)  THEN make_date(EXTRACT(YEAR FROM e.month_start)::int,  7, 28)
         WHEN EXTRACT(MONTH FROM e.month_start) IN (6,7,8)  THEN make_date(EXTRACT(YEAR FROM e.month_start)::int, 10, 28)
         ELSE                                                    make_date(EXTRACT(YEAR FROM e.month_start)::int + 1, 1, 28)
    END                                                                        AS plan_payable_date,

    -- Account dimensions
    e.account_id,
    e.account_title,
    e.bank,
    e.currency,
    e.genre,

    -- Attribution
    e.role,
    e.staff_email,
    u.display AS staff_name,
    u.type    AS staff_type,

    -- Bases (the two columns the dashboard pivots from)
    e.fees                                                                     AS fees,
    e.interest                                                                 AS interest,

    -- Rate and multiplier for THIS row's role
    CASE e.role
        WHEN 'brought_in' THEN u.brought_in
        WHEN 'managed'    THEN u.managed
        WHEN 'supervised' THEN u.supervised
        WHEN 'introducer' THEN u.introducer
    END                                                                        AS rate,
    COALESCE(u.multiple, 1)                                                    AS multiple,
    u.min_threshold                                                            AS quarterly_threshold,

    -- External introducer earns only for introducer_months from account opening.
    -- TRUE for the three staff roles; only constrains the introducer role.
    CASE WHEN e.role <> 'introducer' THEN TRUE
         WHEN u.introducer_months IS NULL OR u.introducer_months = 0 THEN TRUE
         ELSE e.month_start <= (e.account_opened + (u.introducer_months || ' months')::interval)::date
    END                                                                        AS within_introducer_window,

    -- Final commission for this row
    ROUND((
        (e.fees + e.interest)
        * COALESCE(CASE e.role
            WHEN 'brought_in' THEN u.brought_in
            WHEN 'managed'    THEN u.managed
            WHEN 'supervised' THEN u.supervised
            WHEN 'introducer' THEN u.introducer
          END, 0)
        * COALESCE(u.multiple, 1)
        * CASE WHEN e.role = 'introducer'
                AND u.introducer_months > 0
                AND e.month_start > (e.account_opened + (u.introducer_months || ' months')::interval)::date
               THEN 0 ELSE 1 END
    )::numeric, 4)                                                             AS commission

FROM exploded e
LEFT JOIN sys_commission_users u ON lower(u.email) = lower(e.staff_email)
WHERE e.month_start >= DATE '2024-07-01'
ORDER BY e.staff_email, e.month_start, e.account_id, e.role;
