-- =====================================================================
-- Commission super-query.
--
-- Single SELECT that returns commission-relevant data at the finest
-- sensible grain: one row per
--   (month, dp_account, role, staff_email)
-- where role is one of brought_in / managed / supervised / introducer.
-- Use as the source for any summary table on the commission dashboard
-- (per-staff, per-quarter, per-FY etc. — all by aggregation).
--
-- Output columns
--   Period dimensions:
--     month_start, month_end, month_label             (the grain)
--     calendar_quarter_start, _end, _label            (Jan-Mar etc.)
--     plan_fy_year, plan_quarter_num, plan_quarter_label,
--     plan_quarter_start, plan_quarter_end, plan_payable_date
--                                                     (DOS commission
--                                                      plan quarters,
--                                                      FY ending 30 Nov)
--   Account dimensions:
--     account_id, account_title, bank, currency, genre
--   Attribution:
--     role            'brought_in' / 'managed' / 'supervised' / 'introducer'
--     staff_email, staff_display, staff_type
--   Raw bases:
--     fees_attributed         net_amount sum from fees_transactions on
--                             this dp_account in this month
--     interest_attributed     monthly_interest from int_monthly on
--                             this dp_account in this month
--   Rate inputs from sys_commission_users:
--     commission_rate         the staff's rate for this specific role
--     commission_multiple     the staff's multiple
--     quarterly_threshold     the staff's min_threshold (per quarter)
--     within_introducer_window   external introducers only earn for
--                                introducer_months from account opening
--   Calculated:
--     commission_on_fees     = fees_attributed * rate * multiple
--     commission_on_interest = interest_attributed * rate * multiple
--     commission_total       = commission_on_fees + commission_on_interest
--   Gating:
--     within_plan_period      month_start >= 2024-07-01
--
-- Assumptions / design choices to verify
--   1. Interest commission uses the same role rate as fees (the
--      commission letter does not list a separate interest rate).
--      The interest base is int_monthly.monthly_interest (the firm-
--      side amount written by the monthly accrual). If the rate
--      should instead apply to gross client interest, swap the
--      interest_by_month source accordingly.
--   2. The per-role pre-split columns on int_monthly
--      (dp_introduced / dp_managing / dp_supervising) are NOT used.
--      They're sparse (populated on 31 of 872 rows) and the values
--      do not reconcile with monthly_interest. Once their meaning is
--      clarified, we can either drop them upstream or wire them in
--      as the canonical interest commission base.
--   3. int_monthly is deduplicated by picking the most recent
--      created_at per (month_start, dp_account). Older rows (from
--      before the multi-bank refactor) coexist with the new
--      <month>_<account>_<bank>_<currency> rows; we keep the latest.
--   4. fees_transactions are aggregated by date::date and
--      dp_account. Rows with NULL dp_account or NULL date are
--      excluded. account_type = 'SALES' only.
--   5. Bank lookup uses bank_account_sub.dp_account -> bank, taking
--      one bank per dp_account. A dp_account that operates across
--      multiple banks is not yet split by bank here; that's a
--      downstream concern when the data starts to require it.
-- =====================================================================

WITH params AS (
    SELECT
        DATE '2024-07-01'                              AS plan_effective_from,
        date_trunc('month', current_date)::date        AS through_month
),
months AS (
    SELECT m::date AS month_start
    FROM params,
         generate_series(plan_effective_from, through_month, interval '1 month') AS m
),
fees_by_month AS (
    SELECT
        date_trunc('month', date::date)::date AS month_start,
        dp_account                            AS account_id,
        SUM(net_amount)                       AS fees_net
    FROM fees_transactions
    WHERE date IS NOT NULL
      AND account_type = 'SALES'
      AND dp_account IS NOT NULL
    GROUP BY 1, 2
),
-- Deduplicate int_monthly: pick the most recent row per (month, account).
-- Old rows (id = "<month>_<account>") coexist with new multi-bank rows
-- (id = "<month>_<account>_<bank>_<currency>") and can hold stale values.
interest_by_month AS (
    SELECT DISTINCT ON (month_start, dp_account)
        month_start::date                AS month_start,
        dp_account::uuid                 AS account_id,
        COALESCE(monthly_interest, 0)    AS monthly_interest
    FROM int_monthly
    ORDER BY month_start, dp_account, created_at DESC
),
account_dimensions AS (
    SELECT
        a.id                            AS account_id,
        a.title                         AS account_title,
        a.currency                      AS currency,
        pat.genre                       AS genre,
        a.dp_introduced                 AS introduced_email,
        a.dp_managing                   AS managing_email,
        a.dp_supervising                AS supervising_email,
        a.ext_introducer                AS introducer_email,
        a.created_at::date              AS account_created_at,
        (SELECT bank FROM bank_account_sub WHERE dp_account = a.id LIMIT 1) AS bank
    FROM dp_account a
    LEFT JOIN dp_account_type pat ON a.type = pat.id
),
-- One row per (month, account) with fees, interest and the staff
-- emails attached.
attribution AS (
    SELECT
        m.month_start,
        ad.account_id,
        ad.account_title,
        ad.bank,
        ad.currency,
        ad.genre,
        ad.account_created_at,
        ad.introduced_email,
        ad.managing_email,
        ad.supervising_email,
        ad.introducer_email,
        COALESCE(fbm.fees_net, 0)         AS fees_attributed,
        COALESCE(ibm.monthly_interest, 0) AS interest_attributed
    FROM months m
    CROSS JOIN account_dimensions ad
    LEFT JOIN fees_by_month     fbm ON fbm.month_start = m.month_start AND fbm.account_id = ad.account_id
    LEFT JOIN interest_by_month ibm ON ibm.month_start = m.month_start AND ibm.account_id = ad.account_id
),
-- Explode each (month, account) into one row per attributed role.
exploded AS (
    SELECT month_start, account_id, account_title, bank, currency, genre, account_created_at,
           'brought_in'::text AS role, introduced_email AS staff_email,
           fees_attributed, interest_attributed
    FROM attribution WHERE introduced_email IS NOT NULL

    UNION ALL
    SELECT month_start, account_id, account_title, bank, currency, genre, account_created_at,
           'managed', managing_email, fees_attributed, interest_attributed
    FROM attribution WHERE managing_email IS NOT NULL

    UNION ALL
    SELECT month_start, account_id, account_title, bank, currency, genre, account_created_at,
           'supervised', supervising_email, fees_attributed, interest_attributed
    FROM attribution WHERE supervising_email IS NOT NULL

    UNION ALL
    SELECT month_start, account_id, account_title, bank, currency, genre, account_created_at,
           'introducer', introducer_email, fees_attributed, interest_attributed
    FROM attribution WHERE introducer_email IS NOT NULL
),
-- Resolve the rate / multiple for each row from sys_commission_users.
rated AS (
    SELECT
        e.*,
        u.display        AS staff_display,
        u.type           AS staff_type,
        u.multiple       AS commission_multiple_raw,
        u.min_threshold  AS quarterly_threshold,
        u.introducer_months,
        CASE e.role
            WHEN 'brought_in' THEN u.brought_in
            WHEN 'managed'    THEN u.managed
            WHEN 'supervised' THEN u.supervised
            WHEN 'introducer' THEN u.introducer
        END AS commission_rate_raw
    FROM exploded e
    LEFT JOIN sys_commission_users u ON lower(u.email) = lower(e.staff_email)
)
SELECT
    -- Period dimensions: month grain
    month_start,
    (month_start + interval '1 month' - interval '1 day')::date           AS month_end,
    TO_CHAR(month_start, 'YYYY-MM')                                        AS month_label,

    -- Calendar quarter
    DATE_TRUNC('quarter', month_start)::date                               AS calendar_quarter_start,
    (DATE_TRUNC('quarter', month_start) + interval '3 months' - interval '1 day')::date
                                                                           AS calendar_quarter_end,
    EXTRACT(YEAR FROM month_start)::int || '-Q'
        || EXTRACT(QUARTER FROM month_start)::int                         AS calendar_quarter_label,

    -- DOS commission-plan quarter (FY ending 30 Nov, Q1 ends 28 Feb)
    CASE WHEN EXTRACT(MONTH FROM month_start) = 12
         THEN EXTRACT(YEAR FROM month_start)::int + 1
         ELSE EXTRACT(YEAR FROM month_start)::int
    END                                                                    AS plan_fy_year,
    CASE WHEN EXTRACT(MONTH FROM month_start) IN (12, 1, 2) THEN 1
         WHEN EXTRACT(MONTH FROM month_start) IN (3, 4, 5)  THEN 2
         WHEN EXTRACT(MONTH FROM month_start) IN (6, 7, 8)  THEN 3
         ELSE 4
    END                                                                    AS plan_quarter_num,
    'FY' || (CASE WHEN EXTRACT(MONTH FROM month_start) = 12
                  THEN EXTRACT(YEAR FROM month_start)::int + 1
                  ELSE EXTRACT(YEAR FROM month_start)::int END)
         || '-Q' || (CASE WHEN EXTRACT(MONTH FROM month_start) IN (12, 1, 2) THEN 1
                          WHEN EXTRACT(MONTH FROM month_start) IN (3, 4, 5)  THEN 2
                          WHEN EXTRACT(MONTH FROM month_start) IN (6, 7, 8)  THEN 3
                          ELSE 4 END)                                      AS plan_quarter_label,
    CASE WHEN EXTRACT(MONTH FROM month_start) IN (12, 1, 2)
            THEN make_date(
                CASE WHEN EXTRACT(MONTH FROM month_start) = 12
                     THEN EXTRACT(YEAR FROM month_start)::int
                     ELSE EXTRACT(YEAR FROM month_start)::int - 1 END,
                12, 1)
         WHEN EXTRACT(MONTH FROM month_start) IN (3, 4, 5)
            THEN make_date(EXTRACT(YEAR FROM month_start)::int, 3, 1)
         WHEN EXTRACT(MONTH FROM month_start) IN (6, 7, 8)
            THEN make_date(EXTRACT(YEAR FROM month_start)::int, 6, 1)
         ELSE make_date(EXTRACT(YEAR FROM month_start)::int, 9, 1)
    END                                                                    AS plan_quarter_start,
    CASE WHEN EXTRACT(MONTH FROM month_start) IN (12, 1, 2)
            THEN (make_date(
                CASE WHEN EXTRACT(MONTH FROM month_start) = 12
                     THEN EXTRACT(YEAR FROM month_start)::int + 1
                     ELSE EXTRACT(YEAR FROM month_start)::int END,
                3, 1) - interval '1 day')::date
         WHEN EXTRACT(MONTH FROM month_start) IN (3, 4, 5)
            THEN make_date(EXTRACT(YEAR FROM month_start)::int, 5, 30)
         WHEN EXTRACT(MONTH FROM month_start) IN (6, 7, 8)
            THEN make_date(EXTRACT(YEAR FROM month_start)::int, 8, 31)
         ELSE make_date(EXTRACT(YEAR FROM month_start)::int, 11, 30)
    END                                                                    AS plan_quarter_end,
    -- Payable on the usual payroll date in the second month after
    -- quarter end (per plan clause 8.1). Day-of-month fixed at 28 to
    -- be calendar-safe; adjust to your actual payroll day if needed.
    CASE WHEN EXTRACT(MONTH FROM month_start) IN (12, 1, 2)
            THEN make_date(
                CASE WHEN EXTRACT(MONTH FROM month_start) = 12
                     THEN EXTRACT(YEAR FROM month_start)::int + 1
                     ELSE EXTRACT(YEAR FROM month_start)::int END,
                4, 28)
         WHEN EXTRACT(MONTH FROM month_start) IN (3, 4, 5)
            THEN make_date(EXTRACT(YEAR FROM month_start)::int, 7, 28)
         WHEN EXTRACT(MONTH FROM month_start) IN (6, 7, 8)
            THEN make_date(EXTRACT(YEAR FROM month_start)::int, 10, 28)
         ELSE make_date(EXTRACT(YEAR FROM month_start)::int + 1, 1, 28)
    END                                                                    AS plan_payable_date,

    -- Account dimensions
    account_id,
    account_title,
    bank,
    currency,
    genre,

    -- Attribution
    role,
    staff_email,
    staff_display,
    staff_type,

    -- Raw bases
    fees_attributed,
    interest_attributed,

    -- Rate inputs
    commission_rate_raw                              AS commission_rate,
    COALESCE(commission_multiple_raw, 1)             AS commission_multiple,
    quarterly_threshold,

    -- External introducer cap (TRUE for staff roles; for the introducer
    -- role, TRUE only while within introducer_months of account opening).
    CASE WHEN role <> 'introducer' THEN TRUE
         WHEN introducer_months IS NULL OR introducer_months = 0 THEN TRUE
         ELSE month_start <= (account_created_at + (introducer_months || ' months')::interval)::date
    END                                              AS within_introducer_window,

    -- Plan effective gate
    (month_start >= DATE '2024-07-01')               AS within_plan_period,

    -- Computed commission components
    ROUND((
        fees_attributed
        * COALESCE(commission_rate_raw, 0)
        * COALESCE(commission_multiple_raw, 1)
    )::numeric, 4)                                   AS commission_on_fees,
    ROUND((
        interest_attributed
        * COALESCE(commission_rate_raw, 0)
        * COALESCE(commission_multiple_raw, 1)
    )::numeric, 4)                                   AS commission_on_interest,
    ROUND((
        (fees_attributed + interest_attributed)
        * COALESCE(commission_rate_raw, 0)
        * COALESCE(commission_multiple_raw, 1)
    )::numeric, 4)                                   AS commission_total
FROM rated
WHERE month_start >= DATE '2024-07-01'
ORDER BY staff_email, month_start, account_id, role;
