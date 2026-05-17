-- =====================================================================
-- Commission by staff, by month, by currency, by account.
--
-- Drill-down companion to commission_monthly_per_staff.sql. One row
-- per (commission recipient, calendar month, currency, dp_account)
-- with boolean role flags so you can see exactly which roles a staff
-- holds on each account and how each line contributes to the
-- per-staff monthly total.
--
-- Summing the per-account commission columns over (staff, month,
-- currency) reconciles exactly with the per-staff-per-month file.
-- That's the contract.
--
-- A "commission recipient" is anyone who appears in any of the four
-- attribution slots on dp_account (dp_introduced / dp_managing /
-- dp_supervising / ext_introducer). Staff in sys_commission_users
-- but with no attribution on any account in a given month do NOT
-- get zero-rows here (that would explode the row count to
-- staff x month x account). Use commission_monthly_per_staff.sql
-- if you need that.
--
-- from_date on sys_commission_users still prunes early months so
-- new starters do not carry rows from before their start.
--
-- Output columns
--   month_start, month_end, month_label
--   plan_fy_year, plan_quarter_num, plan_quarter_label,
--   plan_quarter_start, plan_quarter_end, commission_payable_on
--   currency
--   account_id, account_title, account_bank, genre
--   staff_email, staff_name, staff_type
--   commission_multiple, quarterly_threshold
--   is_brought_in, is_managing, is_supervising, is_external
--       Boolean: which of the four attribution slots this staff
--       fills on this account. A staff in multiple slots on the
--       same account has multiple TRUE flags on the one row.
--   fees                Net fees on this account this month (same
--                       value regardless of which staff is on the row).
--   interest            Firm-share interest on this account this
--                       month (BoL GBP carry inlined; see header
--                       note in commission_monthly_per_staff.sql).
--   commission_brought_in, commission_managing,
--   commission_supervising, commission_external
--       Per-role commission contribution from this account for
--       this staff. Zero if the matching boolean is FALSE.
--   commission_on_fees, commission_on_interest
--       Split by base, summed across whichever roles this staff
--       fills on this account.
--   month_total
--       Sum of the four per-role commission columns. This is what
--       this row contributes to commission_monthly_per_staff
--       (.month_total / .cumulative etc).
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
        a.title                                    AS account_title,
        COALESCE(a.currency, 'GBP')                AS currency,
        a.created_at::date                         AS account_opened,
        pat.genre                                  AS genre,
        (SELECT bank FROM bank_account_sub
          WHERE dp_account = a.id LIMIT 1)         AS account_bank,
        a.dp_introduced, a.dp_managing, a.dp_supervising, a.ext_introducer,
        COALESCE(mf.fees, 0)                       AS fees,
        COALESCE(mi.interest_firm, 0)              AS interest
    FROM months m
    CROSS JOIN dp_account a
    LEFT JOIN dp_account_type pat ON a.type = pat.id
    LEFT JOIN monthly_fees     mf ON mf.month_start = m.month_start AND mf.account_id = a.id
    LEFT JOIN monthly_interest mi ON mi.month_start = m.month_start AND mi.account_id = a.id
),
-- One row per (month, account, staff) where the staff is named in
-- any of the four attribution slots on the account. Booleans tell
-- you which slots they fill.
account_month_staff AS (
    SELECT
        am.month_start, am.account_id, am.account_title, am.currency,
        am.account_opened, am.genre, am.account_bank,
        am.fees, am.interest,
        s.staff_email,
        COALESCE(lower(am.dp_introduced)  = s.staff_email, FALSE) AS is_brought_in,
        COALESCE(lower(am.dp_managing)    = s.staff_email, FALSE) AS is_managing,
        COALESCE(lower(am.dp_supervising) = s.staff_email, FALSE) AS is_supervising,
        COALESCE(lower(am.ext_introducer) = s.staff_email, FALSE) AS is_external
    FROM account_month am
    CROSS JOIN LATERAL (
        SELECT DISTINCT lower(staff_member) AS staff_email
        FROM (VALUES (am.dp_introduced), (am.dp_managing),
                     (am.dp_supervising), (am.ext_introducer)) AS s(staff_member)
        WHERE staff_member IS NOT NULL
    ) s
),
-- Join rates and apply per-role commission. Filter on from_date so
-- new starters do not appear in pre-start months.
priced AS (
    SELECT
        ams.month_start,
        ams.account_id, ams.account_title, ams.currency, ams.account_bank, ams.genre,
        ams.staff_email,
        u.display       AS staff_name,
        u.type          AS staff_type,
        u.multiple      AS commission_multiple,
        u.min_threshold AS quarterly_threshold,
        ams.is_brought_in, ams.is_managing, ams.is_supervising, ams.is_external,
        ams.fees,
        ams.interest,
        -- Per-role commission contributions on this account
        (CASE WHEN ams.is_brought_in
              THEN (ams.fees + ams.interest) * COALESCE(u.brought_in, 0) * COALESCE(u.multiple, 1)
              ELSE 0 END) AS commission_brought_in,
        (CASE WHEN ams.is_managing
              THEN (ams.fees + ams.interest) * COALESCE(u.managed, 0)    * COALESCE(u.multiple, 1)
              ELSE 0 END) AS commission_managing,
        (CASE WHEN ams.is_supervising
              THEN (ams.fees + ams.interest) * COALESCE(u.supervised, 0) * COALESCE(u.multiple, 1)
              ELSE 0 END) AS commission_supervising,
        (CASE WHEN ams.is_external
              AND NOT (COALESCE(u.introducer_months, 0) > 0
                       AND ams.month_start > (ams.account_opened
                                              + (u.introducer_months || ' months')::interval)::date)
              THEN (ams.fees + ams.interest) * COALESCE(u.introducer, 0) * COALESCE(u.multiple, 1)
              ELSE 0 END) AS commission_external
    FROM account_month_staff ams
    LEFT JOIN sys_commission_users u ON lower(u.email) = ams.staff_email
    WHERE u.from_date IS NULL OR ams.month_start >= u.from_date
)
SELECT
    p.month_start,
    (p.month_start + interval '1 month - 1 day')::date  AS month_end,
    TO_CHAR(p.month_start, 'YYYY-MM')                   AS month_label,
    -- DOS plan quarter (FY ending 30 Nov; Q1 ends 28 Feb)
    CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
         THEN EXTRACT(YEAR FROM p.month_start)::int + 1
         ELSE EXTRACT(YEAR FROM p.month_start)::int
    END                                                 AS plan_fy_year,
    CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12,1,2) THEN 1
         WHEN EXTRACT(MONTH FROM p.month_start) IN (3,4,5)  THEN 2
         WHEN EXTRACT(MONTH FROM p.month_start) IN (6,7,8)  THEN 3
         ELSE 4
    END                                                 AS plan_quarter_num,
    'FY' || (CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                  THEN EXTRACT(YEAR FROM p.month_start)::int + 1
                  ELSE EXTRACT(YEAR FROM p.month_start)::int END)
         || '-Q' || (CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12,1,2) THEN 1
                          WHEN EXTRACT(MONTH FROM p.month_start) IN (3,4,5)  THEN 2
                          WHEN EXTRACT(MONTH FROM p.month_start) IN (6,7,8)  THEN 3
                          ELSE 4 END)                  AS plan_quarter_label,
    CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12,1,2)
            THEN make_date(CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                                THEN EXTRACT(YEAR FROM p.month_start)::int
                                ELSE EXTRACT(YEAR FROM p.month_start)::int - 1 END, 12, 1)
         WHEN EXTRACT(MONTH FROM p.month_start) IN (3,4,5)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int, 3, 1)
         WHEN EXTRACT(MONTH FROM p.month_start) IN (6,7,8)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int, 6, 1)
         ELSE                                               make_date(EXTRACT(YEAR FROM p.month_start)::int, 9, 1)
    END                                                 AS plan_quarter_start,
    CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12,1,2)
            THEN (make_date(CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                                 THEN EXTRACT(YEAR FROM p.month_start)::int + 1
                                 ELSE EXTRACT(YEAR FROM p.month_start)::int END, 3, 1) - interval '1 day')::date
         WHEN EXTRACT(MONTH FROM p.month_start) IN (3,4,5)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int, 5, 30)
         WHEN EXTRACT(MONTH FROM p.month_start) IN (6,7,8)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int, 8, 31)
         ELSE                                               make_date(EXTRACT(YEAR FROM p.month_start)::int, 11, 30)
    END                                                 AS plan_quarter_end,
    CASE WHEN EXTRACT(MONTH FROM p.month_start) IN (12,1,2)
            THEN make_date(CASE WHEN EXTRACT(MONTH FROM p.month_start) = 12
                                THEN EXTRACT(YEAR FROM p.month_start)::int + 1
                                ELSE EXTRACT(YEAR FROM p.month_start)::int END, 4, 28)
         WHEN EXTRACT(MONTH FROM p.month_start) IN (3,4,5)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int, 7, 28)
         WHEN EXTRACT(MONTH FROM p.month_start) IN (6,7,8)  THEN make_date(EXTRACT(YEAR FROM p.month_start)::int, 10, 28)
         ELSE                                               make_date(EXTRACT(YEAR FROM p.month_start)::int + 1, 1, 28)
    END                                                 AS commission_payable_on,

    p.currency,
    p.account_id,
    p.account_title,
    p.account_bank,
    p.genre,
    p.staff_email,
    p.staff_name,
    p.staff_type,
    p.commission_multiple,
    p.quarterly_threshold,

    p.is_brought_in,
    p.is_managing,
    p.is_supervising,
    p.is_external,

    ROUND(p.fees::numeric,                       4) AS fees,
    ROUND(p.interest::numeric,                   4) AS interest,
    ROUND(p.commission_brought_in::numeric,      4) AS commission_brought_in,
    ROUND(p.commission_managing::numeric,        4) AS commission_managing,
    ROUND(p.commission_supervising::numeric,     4) AS commission_supervising,
    ROUND(p.commission_external::numeric,        4) AS commission_external,
    -- Split by base, computed from the role contributions: each role
    -- contributes (fees + interest) * rate * multiple; split out by
    -- multiplying by fees / (fees + interest) and interest / (fees + interest).
    -- Done arithmetically to avoid re-deriving the rates here.
    ROUND((CASE WHEN (p.fees + p.interest) = 0 THEN 0
                ELSE (p.commission_brought_in + p.commission_managing + p.commission_supervising + p.commission_external)
                     * p.fees / (p.fees + p.interest) END)::numeric, 4) AS commission_on_fees,
    ROUND((CASE WHEN (p.fees + p.interest) = 0 THEN 0
                ELSE (p.commission_brought_in + p.commission_managing + p.commission_supervising + p.commission_external)
                     * p.interest / (p.fees + p.interest) END)::numeric, 4) AS commission_on_interest,
    ROUND((p.commission_brought_in + p.commission_managing + p.commission_supervising + p.commission_external)::numeric, 4)
                                                       AS month_total
FROM priced p
ORDER BY p.staff_email, p.currency, p.month_start, p.account_title;
