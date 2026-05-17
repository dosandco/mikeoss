-- Metabase question: Commission - Fees attribution detail
--
-- Per-line breakdown: every fees_transactions row, exploded by role,
-- showing how commission is calculated. Use this for spot-checking the
-- summary and for the line-by-line table on the dashboard.
--
-- Parameters:
--   {{staff_email}} text   optional
--   {{fy_year}}     number optional
--   {{quarter_num}} number optional 1-4
--   {{role}}        text   optional - one of brought_in / managed / supervised / introducer

SELECT
  relevant_date          AS "Relevant date",
  quarter_label          AS "Quarter",
  account_brand          AS "Brand",
  account_name           AS "Account name",
  account_title          AS "Account title",
  reference              AS "Reference",
  description            AS "Description",
  business_type          AS "Type",
  role                   AS "Role",
  attributed_name        AS "Staff",
  attributed_email       AS "Email",
  net_amount             AS "Net amount",
  commission_rate        AS "Rate",
  commission_multiple    AS "Multiple",
  within_plan_period     AS "Within plan period?",
  within_introducer_window AS "Within introducer window?",
  commission_amount      AS "Commission"
FROM commission.vw_fees_attributions
WHERE 1 = 1
  [[ AND lower(attributed_email) = lower({{staff_email}}) ]]
  [[ AND fy_year     = {{fy_year}} ]]
  [[ AND quarter_num = {{quarter_num}} ]]
  [[ AND role        = {{role}} ]]
ORDER BY relevant_date DESC, account_name, role;
