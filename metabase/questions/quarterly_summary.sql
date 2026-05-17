-- Metabase question: Commission - Quarterly Summary
--
-- One row per (staff member, fiscal quarter). Use as the canonical
-- "what am I being paid this quarter?" view.
--
-- Parameters (Metabase variables):
--   {{staff_email}}  text   optional, e.g. 'ph@dosandco.com'
--   {{fy_year}}      number optional, e.g. 2025
--   {{quarter_num}}  number optional, 1-4
--
-- Sort: most recent quarter first, then alphabetical by staff name.

SELECT
  attributed_name        AS "Staff",
  attributed_email       AS "Email",
  user_type              AS "Type",
  quarter_label          AS "Quarter",
  quarter_start          AS "Quarter start",
  quarter_end            AS "Quarter end",
  payroll_date           AS "Payroll date",
  attributed_sales_gross AS "Attributed sales (net of tax)",
  min_threshold          AS "Threshold",
  threshold_met          AS "Threshold met?",
  threshold_shortfall    AS "Shortfall to threshold",
  commission_brought_in  AS "Commission: Brought In",
  commission_managed     AS "Commission: Managed",
  commission_supervised  AS "Commission: Supervised",
  commission_introducer  AS "Commission: Introducer",
  commission_fees_total  AS "Commission: Fees subtotal",
  commission_interest_total AS "Commission: Interest subtotal",
  commission_total       AS "Commission total"
FROM commission.vw_commission_quarterly
WHERE 1 = 1
  [[ AND lower(attributed_email) = lower({{staff_email}}) ]]
  [[ AND fy_year     = {{fy_year}} ]]
  [[ AND quarter_num = {{quarter_num}} ]]
ORDER BY fy_year DESC, quarter_num DESC, attributed_name;
