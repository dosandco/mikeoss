-- =====================================================================
-- Commission by staff, by month, by currency.
--
-- One row per (commission recipient, calendar month, currency) with
-- the four attribution roles pivoted into columns and three running
-- totals to the end of each month.
--
-- A "commission recipient" is anyone who EITHER appears in
-- sys_commission_users OR is named in a dp_account attribution slot
-- (dp_introduced / dp_managing / dp_supervising / ext_introducer).
--
-- Each recipient appears in every month from when they became
-- eligible (sys_commission_users.from_date) through to the current
-- month, even when they earned zero, so the dashboard can render
-- an unbroken time series per person. Attribution-only staff (not
-- in sys_commission_users) appear in every month so they remain
-- visible as needing rate configuration.
--
-- Multi-currency
-- --------------
-- The grain includes currency so each recipient appears once per
-- (month, currency) they have exposure to. Today all dp_accounts
-- are GBP, so every row has currency = 'GBP'. When USD or EUR
-- accounts open, those accounts' fees and interest produce
-- additional rows in those currencies without any structural
-- change to this query.
--
-- All amounts are in the row's native currency; no FX conversion
-- is attempted. The dashboard layer (or a future FX rates table)
-- handles cross-currency comparison / consolidation.
--
-- Two upstream gaps to address before multi-currency goes live:
--   * int_monthly has no currency column today. The monthly
--     interest will need to be re-aggregated per (account, currency)
--     by the official monthly_interest_accrual job, and the
--     monthly_interest CTE here will need to join on currency.
--   * comm_paid has no currency column today. Today total_paid is
--     correct because every payment is GBP; when payments are made
--     in other currencies, add a currency column and amend the
--     total_paid subquery to filter on it.
--
-- The underlying calculation chain is identical to
-- commission_super_query.sql (which exposes the same data at row
-- grain — one row per (month, account, role, staff) — useful for
-- drill-down). The only difference here is the final aggregation /
-- pivot to per-staff-per-month-per-currency with windowed totals.
--
-- Output columns
--   month_start, month_end, month_label              the grain
--   plan_fy_year, plan_quarter_num, plan_quarter_label,
--   plan_quarter_start, plan_quarter_end,
--   commission_payable_on                            DOS plan fiscal
--                                                    periods and the
--                                                    payable date for
--                                                    this month's
--                                                    commission
--   currency                                         the row's native
--                                                    currency
--   staff_email, staff_name, staff_type              recipient
--   commission_multiple, quarterly_threshold         from
--                                                    sys_commission_users
--   introduced     commission earned in the brought_in role
--   managing       commission earned in the managed role
--   supervising    commission earned in the supervised role
--   external       commission earned as ext_introducer (capped by
--                  introducer_months from account opening)
--   month_total    sum of the four role columns
--   cumulative     running sum of month_total per (staff, currency),
--                  since the plan effective date (no FY reset)
--   fy_to_date     running sum within each plan FY (resets each Dec)
--   quarter_to_date running sum within each plan quarter (resets each
--                   plan quarter)
--   total_paid     sum of every comm_paid.amount to this recipient
--                  where comm_paid.date <= month_end. Includes any
--                  pre-plan-effective payments, so the running
--                  balance starts from a complete payment history.
--                  Today only attached to GBP rows (see comm_paid
--                  gap above).
--   to_pay         cumulative - total_paid. Naturally signed: a
--                  negative value means the recipient has been paid
--                  more than the dashboard has recorded as earned.
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
-- Carry inlined for BoL GBP (every account in production today). When
-- ClearBank/Federated Hermes go live, OR int_monthly is enriched with
-- a persisted dp_interest column, simplify this CTE accordingly.
monthly_interest AS (
    SELECT DISTINCT ON (im.month_start, im.dp_account)
        im.month_start::date              AS month_start,
        a.id                              AS account_id,
        COALESCE(im.monthly_interest, 0)
          * CASE pat.genre
              WHEN 'Deposit Accounts'  THEN 0.10
              WHEN 'Escrow Accounts'   THEN CASE WHEN im.month_start >= DATE '2025-03-01' THEN 0.75 ELSE 0.50 END
              WHEN 'Payment Accounts'  THEN CASE WHEN im.month_start >= DATE '2025-03-01' THEN 0.75 ELSE 0.50 END
              ELSE 0
            END                           AS interest_firm
    FROM int_monthly im
    JOIN dp_account a            ON a.id::text = im.dp_account
    LEFT JOIN dp_account_type pat ON a.type = pat.id
    ORDER BY im.month_start, im.dp_account, im.created_at DESC
),
account_month AS (
    SELECT
        m.month_start,
        a.id                                       AS account_id,
        COALESCE(a.currency, 'GBP')                AS currency,
        a.created_at::date                         AS account_opened,
        a.dp_introduced, a.dp_managing, a.dp_supervising, a.ext_introducer,
        COALESCE(mf.fees, 0)                       AS fees,
        COALESCE(mi.interest_firm, 0)              AS interest
    FROM months m
    CROSS JOIN dp_account a
    LEFT JOIN monthly_fees     mf ON mf.month_start = m.month_start AND mf.account_id = a.id
    LEFT JOIN monthly_interest mi ON mi.month_start = m.month_start AND mi.account_id = a.id
),
-- One row per (month, account, role, staff, currency).
exploded AS (
    SELECT month_start, account_id, account_opened, currency,
           'brought_in'::text AS role, dp_introduced AS staff_email, fees, interest
    FROM account_month WHERE dp_introduced IS NOT NULL
    UNION ALL
    SELECT month_start, account_id, account_opened, currency,
           'managed',    dp_managing,    fees, interest
    FROM account_month WHERE dp_managing    IS NOT NULL
    UNION ALL
    SELECT month_start, account_id, account_opened, currency,
           'supervised', dp_supervising, fees, interest
    FROM account_month WHERE dp_supervising IS NOT NULL
    UNION ALL
    SELECT month_start, account_id, account_opened, currency,
           'introducer', ext_introducer, fees, interest
    FROM account_month WHERE ext_introducer IS NOT NULL
),
-- Every (recipient, currency) pair that should appear in the output.
-- Attribution-only staff (not in sys_commission_users) are kept so
-- they remain visible as "configured for attribution but missing
-- from sys_commission_users". sys_commission_users entries default
-- to GBP since rates are not currency-scoped today.
all_staff_currencies AS (
    SELECT DISTINCT lower(e.staff_email) AS staff_email, e.currency
    FROM exploded e
    UNION
    SELECT DISTINCT lower(u.email)       AS staff_email, 'GBP'::text AS currency
    FROM sys_commission_users u
),
staff_currency_months AS (
    -- One row per (staff, currency, month) that the staff was eligible
    -- in. A staff with a from_date on sys_commission_users only
    -- appears from that date onwards.
    SELECT m.month_start, sc.staff_email, sc.currency
    FROM months m
    CROSS JOIN all_staff_currencies sc
    LEFT JOIN sys_commission_users u ON lower(u.email) = sc.staff_email
    WHERE u.from_date IS NULL
       OR m.month_start >= u.from_date
),
-- Pivot to per-staff-per-month-per-currency with four role-typed
-- commission columns.
per_staff_month AS (
    SELECT
        scm.month_start,
        scm.staff_email,
        scm.currency,
        u.display       AS staff_name,
        u.type          AS staff_type,
        u.multiple      AS commission_multiple,
        u.min_threshold AS quarterly_threshold,
        COALESCE(SUM(CASE WHEN e.role = 'brought_in' THEN
            (e.fees + e.interest) * COALESCE(u.brought_in, 0) * COALESCE(u.multiple, 1)
        ELSE 0 END), 0)                  AS introduced,
        COALESCE(SUM(CASE WHEN e.role = 'managed' THEN
            (e.fees + e.interest) * COALESCE(u.managed, 0)    * COALESCE(u.multiple, 1)
        ELSE 0 END), 0)                  AS managing,
        COALESCE(SUM(CASE WHEN e.role = 'supervised' THEN
            (e.fees + e.interest) * COALESCE(u.supervised, 0) * COALESCE(u.multiple, 1)
        ELSE 0 END), 0)                  AS supervising,
        COALESCE(SUM(CASE WHEN e.role = 'introducer'
                            AND NOT (COALESCE(u.introducer_months, 0) > 0
                                     AND e.month_start > (e.account_opened
                                                          + (u.introducer_months || ' months')::interval)::date)
                          THEN (e.fees + e.interest) * COALESCE(u.introducer, 0) * COALESCE(u.multiple, 1)
                          ELSE 0 END), 0) AS external
    FROM staff_currency_months scm
    LEFT JOIN exploded e
      ON e.month_start = scm.month_start
     AND lower(e.staff_email) = scm.staff_email
     AND e.currency = scm.currency
    LEFT JOIN sys_commission_users u
      ON lower(u.email) = scm.staff_email
    GROUP BY scm.month_start, scm.staff_email, scm.currency,
             u.display, u.type, u.multiple, u.min_threshold
),
-- Tag each row with the period dimensions and the within-row total.
with_periods AS (
    SELECT
        p.month_start,
        (p.month_start + interval '1 month - 1 day')::date AS month_end,
        TO_CHAR(p.month_start, 'YYYY-MM')                  AS month_label,
        -- DOS plan quarter (FY ending 30 Nov; Q1 ends 28 Feb)
        CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
             THEN EXTRACT(YEAR FROM p.month_start)::int + 1
             ELSE EXTRACT(YEAR FROM p.month_start)::int
        END                                                AS plan_fy_year,
        CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12, 1, 2) THEN 1
             WHEN EXTRACT(MONTH FROM p.month_start) IN (3, 4, 5)  THEN 2
             WHEN EXTRACT(MONTH FROM p.month_start) IN (6, 7, 8)  THEN 3
             ELSE 4
        END                                                AS plan_quarter_num,
        'FY' || (CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                      THEN EXTRACT(YEAR FROM p.month_start)::int + 1
                      ELSE EXTRACT(YEAR FROM p.month_start)::int END)
             || '-Q' || (CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12, 1, 2) THEN 1
                              WHEN EXTRACT(MONTH FROM p.month_start) IN (3, 4, 5)  THEN 2
                              WHEN EXTRACT(MONTH FROM p.month_start) IN (6, 7, 8)  THEN 3
                              ELSE 4 END)                  AS plan_quarter_label,
        CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12, 1, 2)
                THEN make_date(CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                                    THEN EXTRACT(YEAR FROM p.month_start)::int
                                    ELSE EXTRACT(YEAR FROM p.month_start)::int - 1 END,
                               12, 1)
             WHEN EXTRACT(MONTH FROM p.month_start) IN (3, 4, 5)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int,  3, 1)
             WHEN EXTRACT(MONTH FROM p.month_start) IN (6, 7, 8)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int,  6, 1)
             ELSE                                                      make_date(EXTRACT(YEAR FROM p.month_start)::int,  9, 1)
        END                                                AS plan_quarter_start,
        CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12, 1, 2)
                THEN (make_date(CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                                     THEN EXTRACT(YEAR FROM p.month_start)::int + 1
                                     ELSE EXTRACT(YEAR FROM p.month_start)::int END,
                                3, 1) - interval '1 day')::date
             WHEN EXTRACT(MONTH FROM p.month_start) IN (3, 4, 5)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int,  5, 30)
             WHEN EXTRACT(MONTH FROM p.month_start) IN (6, 7, 8)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int,  8, 31)
             ELSE                                                      make_date(EXTRACT(YEAR FROM p.month_start)::int, 11, 30)
        END                                                AS plan_quarter_end,
        -- Per plan clause 8.1, commission is paid on the usual
        -- payroll date in the second calendar month following the
        -- end of the quarter in which the row's month falls. So a
        -- month in plan Q2 (Mar/Apr/May) is payable on the July
        -- payroll. Day-of-month fixed at 28 for calendar safety.
        CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12, 1, 2)
                THEN make_date(CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                                    THEN EXTRACT(YEAR FROM p.month_start)::int + 1
                                    ELSE EXTRACT(YEAR FROM p.month_start)::int END,
                               4, 28)
             WHEN EXTRACT(MONTH FROM p.month_start) IN (3, 4, 5)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int,  7, 28)
             WHEN EXTRACT(MONTH FROM p.month_start) IN (6, 7, 8)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int, 10, 28)
             ELSE                                                      make_date(EXTRACT(YEAR FROM p.month_start)::int + 1, 1, 28)
        END                                                AS commission_payable_on,
        p.staff_email, p.staff_name, p.staff_type, p.currency,
        p.commission_multiple, p.quarterly_threshold,
        p.introduced, p.managing, p.supervising, p.external,
        (p.introduced + p.managing + p.supervising + p.external) AS month_total
    FROM per_staff_month p
),
final AS (
    SELECT
        month_start, month_end, month_label,
        plan_fy_year, plan_quarter_num, plan_quarter_label,
        plan_quarter_start, plan_quarter_end, commission_payable_on,
        currency,
        staff_email, staff_name, staff_type,
        commission_multiple, quarterly_threshold,
        introduced, managing, supervising, external, month_total,
        SUM(month_total) OVER (
            PARTITION BY staff_email, currency
            ORDER BY month_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS cumulative,
        SUM(month_total) OVER (
            PARTITION BY staff_email, currency, plan_fy_year
            ORDER BY month_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS fy_to_date,
        SUM(month_total) OVER (
            PARTITION BY staff_email, currency, plan_quarter_label
            ORDER BY month_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS quarter_to_date,
        -- Total commission paid out to this recipient on or before
        -- the end of this month. comm_paid has no currency column
        -- today (every payment is GBP), so payments are only joined
        -- to GBP rows; other currencies start at 0 until comm_paid
        -- gains a currency column.
        CASE WHEN wp.currency = 'GBP' THEN
            (SELECT COALESCE(SUM(amount), 0)
               FROM comm_paid cp
               WHERE lower(cp.paid_to) = wp.staff_email
                 AND cp.date::date <= wp.month_end)
        ELSE 0 END AS total_paid
    FROM with_periods wp
)
SELECT
    month_start, month_end, month_label,
    plan_fy_year, plan_quarter_num, plan_quarter_label,
    plan_quarter_start, plan_quarter_end, commission_payable_on,
    currency,
    staff_email, staff_name, staff_type,
    commission_multiple, quarterly_threshold,
    ROUND(introduced::numeric,      4) AS introduced,
    ROUND(managing::numeric,        4) AS managing,
    ROUND(supervising::numeric,     4) AS supervising,
    ROUND(external::numeric,        4) AS external,
    ROUND(month_total::numeric,     4) AS month_total,
    ROUND(cumulative::numeric,      4) AS cumulative,
    ROUND(fy_to_date::numeric,      4) AS fy_to_date,
    ROUND(quarter_to_date::numeric, 4) AS quarter_to_date,
    ROUND(total_paid::numeric,      4) AS total_paid,
    ROUND((cumulative - total_paid)::numeric, 4) AS to_pay
FROM final
ORDER BY staff_email, currency, month_start;
