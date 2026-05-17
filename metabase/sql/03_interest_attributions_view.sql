-- Per-staff, per-quarter interest commission, derived from int_quarterly.
--
-- int_quarterly already holds the per-role split of interest commission
-- for each (account, quarter): dp_introduced_int / dp_managing_int /
-- dp_supervising_int. These are pre-computed amounts (not raw interest)
-- and are taken at face value here. Multiplier from sys_commission_users
-- is then applied to align with the Commission Plan clause 5.1.b. Set
-- the multiple to 1 if int_quarterly already incorporates it.

CREATE OR REPLACE VIEW commission.vw_interest_attributions AS
WITH base AS (
  SELECT
    iq.unique_id,
    iq.account_id,
    iq.quarter_start::date AS quarter_start_in,
    iq.quarter_end::date   AS quarter_end_in,
    iq.payable::date       AS payable_date,
    iq.dp_introduced,
    iq.dp_managing,
    iq.dp_supervising,
    iq.dp_introduced_int,
    iq.dp_managing_int,
    iq.dp_supervising_int,
    iq.quarterly_interest,
    iq.end_of_quarter_balance,
    iq.dp_interest
  FROM public.int_quarterly iq
),
exploded AS (
  SELECT b.unique_id, b.account_id, b.quarter_start_in, b.quarter_end_in, b.payable_date,
         'brought_in'::text AS role,
         b.dp_introduced    AS attributed_email,
         b.dp_introduced_int AS interest_share,
         b.quarterly_interest, b.end_of_quarter_balance
  FROM base b WHERE b.dp_introduced IS NOT NULL AND b.dp_introduced_int IS NOT NULL

  UNION ALL

  SELECT b.unique_id, b.account_id, b.quarter_start_in, b.quarter_end_in, b.payable_date,
         'managed', b.dp_managing, b.dp_managing_int,
         b.quarterly_interest, b.end_of_quarter_balance
  FROM base b WHERE b.dp_managing IS NOT NULL AND b.dp_managing_int IS NOT NULL

  UNION ALL

  SELECT b.unique_id, b.account_id, b.quarter_start_in, b.quarter_end_in, b.payable_date,
         'supervised', b.dp_supervising, b.dp_supervising_int,
         b.quarterly_interest, b.end_of_quarter_balance
  FROM base b WHERE b.dp_supervising IS NOT NULL AND b.dp_supervising_int IS NOT NULL
)
SELECT
  e.unique_id,
  e.account_id,
  e.quarter_start_in,
  e.quarter_end_in,
  e.payable_date,
  q.fy_year,
  q.quarter_num,
  q.quarter_label,
  q.quarter_start,
  q.quarter_end,
  q.payroll_date,
  e.role,
  e.attributed_email,
  u.display AS attributed_name,
  u.type    AS user_type,
  e.quarterly_interest,
  e.end_of_quarter_balance,
  e.interest_share,
  COALESCE(u.multiple, 1) AS commission_multiple,
  (e.quarter_end_in >= DATE '2024-07-01') AS within_plan_period,
  CASE
    WHEN e.quarter_end_in < DATE '2024-07-01' THEN 0
    ELSE COALESCE(e.interest_share, 0) * COALESCE(u.multiple, 1)
  END AS commission_amount
FROM exploded e
LEFT JOIN public.sys_commission_users u ON lower(u.email) = lower(e.attributed_email)
CROSS JOIN LATERAL commission.dos_fy_quarter(e.quarter_end_in) q;

COMMENT ON VIEW commission.vw_interest_attributions
  IS 'Per-staff, per-quarter interest commission derived from int_quarterly pre-split columns.';
