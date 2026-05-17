-- One row per (fees_transaction, attributed staff member, role).
--
-- A single fees_transactions line can be attributed up to three times to
-- internal staff (Brought In / Managed / Supervised) plus once to an
-- external introducer. Each attribution earns commission at the rate
-- set on sys_commission_users for that role, scaled by the user's
-- commission multiple.
--
-- The plan distinguishes Completed Sales (New Business) from Completed
-- Renewals at different rates. There is no classification column on
-- fees_transactions today, so every line is treated as New Business
-- (business_type='new_business'). Pete's letter sets both rates equal,
-- so this has no numeric effect for him today. When a renewal flag is
-- added (e.g. fees_transactions.is_renewal or a tracking_category
-- mapping), update the business_type CASE below and rename the rate
-- columns picked.
--
-- Relevant Date: per the plan, the date the fee was received in full.
-- fees_transactions.date is the authoritative column; if NULL we fall
-- back to created_at so the view returns rows during onboarding. Update
-- the COALESCE if your "received in full" timestamp lives elsewhere.

CREATE OR REPLACE VIEW commission.vw_fees_attributions AS
WITH base AS (
  SELECT
    ft.journal_line_id,
    ft.reference,
    ft.account_type,
    ft.account_name,
    ft.description,
    ft.net_amount,
    COALESCE(ft.date, ft.created_at)::date AS relevant_date,
    ft.dp_account,
    da.title         AS account_title,
    da.brand         AS account_brand,
    da.dp_introduced,
    da.dp_managing,
    da.dp_supervising,
    da.ext_introducer,
    da.created_at    AS account_created_at,
    -- Placeholder until a renewal classification exists on fees_transactions.
    'new_business'::text AS business_type
  FROM public.fees_transactions ft
  LEFT JOIN public.dp_account da ON da.id = ft.dp_account
  WHERE ft.account_type = 'SALES'
),
exploded AS (
  -- Brought In (introducer staff)
  SELECT
    b.journal_line_id,
    b.relevant_date,
    b.reference,
    b.account_type,
    b.account_name,
    b.description,
    b.net_amount,
    b.dp_account,
    b.account_title,
    b.account_brand,
    b.business_type,
    'brought_in'::text AS role,
    b.dp_introduced    AS attributed_email
  FROM base b
  WHERE b.dp_introduced IS NOT NULL

  UNION ALL

  -- Relationship Managed
  SELECT
    b.journal_line_id, b.relevant_date, b.reference, b.account_type, b.account_name,
    b.description, b.net_amount, b.dp_account, b.account_title, b.account_brand,
    b.business_type,
    'managed'::text, b.dp_managing
  FROM base b
  WHERE b.dp_managing IS NOT NULL

  UNION ALL

  -- Supervised
  SELECT
    b.journal_line_id, b.relevant_date, b.reference, b.account_type, b.account_name,
    b.description, b.net_amount, b.dp_account, b.account_title, b.account_brand,
    b.business_type,
    'supervised'::text, b.dp_supervising
  FROM base b
  WHERE b.dp_supervising IS NOT NULL

  UNION ALL

  -- External introducer (capped by introducer_months from sys_commission_users)
  SELECT
    b.journal_line_id, b.relevant_date, b.reference, b.account_type, b.account_name,
    b.description, b.net_amount, b.dp_account, b.account_title, b.account_brand,
    b.business_type,
    'introducer'::text, b.ext_introducer
  FROM base b
  WHERE b.ext_introducer IS NOT NULL
)
SELECT
  e.journal_line_id,
  e.relevant_date,
  q.fy_year,
  q.quarter_num,
  q.quarter_label,
  q.quarter_start,
  q.quarter_end,
  q.payroll_date,
  e.reference,
  e.account_type,
  e.account_name,
  e.description,
  e.dp_account,
  e.account_title,
  e.account_brand,
  e.business_type,
  e.role,
  e.attributed_email,
  u.display       AS attributed_name,
  u.type          AS user_type,
  e.net_amount,
  -- Per-role rate from sys_commission_users
  CASE e.role
    WHEN 'brought_in' THEN u.brought_in
    WHEN 'managed'    THEN u.managed
    WHEN 'supervised' THEN u.supervised
    WHEN 'introducer' THEN u.introducer
  END AS commission_rate,
  COALESCE(u.multiple, 1) AS commission_multiple,
  -- Introducer cap: external introducers only earn for the first
  -- introducer_months months after the account was created.
  CASE
    WHEN e.role <> 'introducer' THEN TRUE
    WHEN u.introducer_months IS NULL OR u.introducer_months = 0 THEN TRUE
    ELSE e.relevant_date
         <= ((SELECT created_at FROM public.dp_account WHERE id = e.dp_account)
             + (u.introducer_months || ' months')::interval)::date
  END AS within_introducer_window,
  -- Plan effective from 1 July 2024.
  (e.relevant_date >= DATE '2024-07-01') AS within_plan_period,
  -- Commission earned on this line for this attribution.
  -- (rate * net_amount * multiple), zeroed if outside introducer window
  -- or before the plan effective date.
  CASE
    WHEN e.relevant_date < DATE '2024-07-01' THEN 0
    WHEN e.role = 'introducer'
      AND e.relevant_date >
        ((SELECT created_at FROM public.dp_account WHERE id = e.dp_account)
         + (COALESCE(u.introducer_months, 0) || ' months')::interval)::date
      THEN 0
    ELSE COALESCE(e.net_amount, 0)
         * COALESCE(CASE e.role
                      WHEN 'brought_in' THEN u.brought_in
                      WHEN 'managed'    THEN u.managed
                      WHEN 'supervised' THEN u.supervised
                      WHEN 'introducer' THEN u.introducer
                    END, 0)
         * COALESCE(u.multiple, 1)
  END AS commission_amount
FROM exploded e
LEFT JOIN public.sys_commission_users u ON lower(u.email) = lower(e.attributed_email)
CROSS JOIN LATERAL commission.dos_fy_quarter(e.relevant_date) q;

COMMENT ON VIEW commission.vw_fees_attributions
  IS 'One row per (fees transaction, attributed user, role) with rate and commission applied.';
