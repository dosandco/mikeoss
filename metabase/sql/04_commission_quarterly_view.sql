-- Aggregate commission per (staff member, fiscal quarter).
--
-- Unions the fees and interest attribution streams and produces one row
-- per user per quarter, with the three commission plan checks applied:
--
--   * Plan effective from 1 July 2024 (clause 5.3) — already enforced
--     in the underlying views.
--   * Minimum quarterly sales threshold (clause 5.2 + Commission Letter).
--     "Sales" here = the user's attributed gross fee revenue for the
--     quarter (sum of net_amount on lines they're credited on, in any
--     role). Threshold gating is reported but does NOT zero the payable
--     so the dashboard can show "qualifying / not yet qualifying" state.
--   * Commission Multiple (clause 5.1.b) — applied per-line in the
--     underlying views so it does not need to be re-applied here.

CREATE OR REPLACE VIEW commission.vw_commission_quarterly AS
WITH fees AS (
  SELECT
    attributed_email,
    attributed_name,
    user_type,
    fy_year,
    quarter_num,
    quarter_label,
    quarter_start,
    quarter_end,
    payroll_date,
    SUM(CASE WHEN role IN ('brought_in','managed','supervised','introducer')
             THEN net_amount ELSE 0 END)             AS attributed_sales_gross,
    SUM(CASE WHEN role = 'brought_in' THEN commission_amount ELSE 0 END)
                                                     AS commission_brought_in,
    SUM(CASE WHEN role = 'managed'    THEN commission_amount ELSE 0 END)
                                                     AS commission_managed,
    SUM(CASE WHEN role = 'supervised' THEN commission_amount ELSE 0 END)
                                                     AS commission_supervised,
    SUM(CASE WHEN role = 'introducer' THEN commission_amount ELSE 0 END)
                                                     AS commission_introducer,
    SUM(commission_amount)                           AS commission_fees_total
  FROM commission.vw_fees_attributions
  WHERE within_plan_period
  GROUP BY attributed_email, attributed_name, user_type,
           fy_year, quarter_num, quarter_label, quarter_start, quarter_end, payroll_date
),
interest AS (
  SELECT
    attributed_email,
    attributed_name,
    user_type,
    fy_year,
    quarter_num,
    quarter_label,
    quarter_start,
    quarter_end,
    payroll_date,
    SUM(commission_amount) AS commission_interest_total
  FROM commission.vw_interest_attributions
  WHERE within_plan_period
  GROUP BY attributed_email, attributed_name, user_type,
           fy_year, quarter_num, quarter_label, quarter_start, quarter_end, payroll_date
),
merged AS (
  SELECT
    COALESCE(f.attributed_email, i.attributed_email) AS attributed_email,
    COALESCE(f.attributed_name,  i.attributed_name)  AS attributed_name,
    COALESCE(f.user_type,        i.user_type)        AS user_type,
    COALESCE(f.fy_year,          i.fy_year)          AS fy_year,
    COALESCE(f.quarter_num,      i.quarter_num)      AS quarter_num,
    COALESCE(f.quarter_label,    i.quarter_label)    AS quarter_label,
    COALESCE(f.quarter_start,    i.quarter_start)    AS quarter_start,
    COALESCE(f.quarter_end,      i.quarter_end)      AS quarter_end,
    COALESCE(f.payroll_date,     i.payroll_date)     AS payroll_date,
    COALESCE(f.attributed_sales_gross,    0) AS attributed_sales_gross,
    COALESCE(f.commission_brought_in,     0) AS commission_brought_in,
    COALESCE(f.commission_managed,        0) AS commission_managed,
    COALESCE(f.commission_supervised,     0) AS commission_supervised,
    COALESCE(f.commission_introducer,     0) AS commission_introducer,
    COALESCE(f.commission_fees_total,     0) AS commission_fees_total,
    COALESCE(i.commission_interest_total, 0) AS commission_interest_total
  FROM fees f
  FULL OUTER JOIN interest i
    ON  f.attributed_email = i.attributed_email
    AND f.fy_year          = i.fy_year
    AND f.quarter_num      = i.quarter_num
)
SELECT
  m.*,
  (m.commission_fees_total + m.commission_interest_total) AS commission_total,
  u.min_threshold,
  (m.attributed_sales_gross >= COALESCE(u.min_threshold, 0)) AS threshold_met,
  GREATEST(COALESCE(u.min_threshold, 0) - m.attributed_sales_gross, 0)
                                                            AS threshold_shortfall
FROM merged m
LEFT JOIN public.sys_commission_users u ON lower(u.email) = lower(m.attributed_email);

COMMENT ON VIEW commission.vw_commission_quarterly
  IS 'One row per staff member per fiscal quarter: fees + interest commission with threshold check.';
