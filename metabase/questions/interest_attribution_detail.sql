-- Metabase question: Commission - Interest attribution detail
--
-- Per-account, per-quarter interest commission lines.
--
-- Parameters:
--   {{staff_email}} text   optional
--   {{fy_year}}     number optional
--   {{quarter_num}} number optional 1-4
--   {{role}}        text   optional

SELECT
  quarter_label          AS "Quarter",
  quarter_end_in         AS "Quarter end (data)",
  payable_date           AS "Payable",
  account_id             AS "Account",
  role                   AS "Role",
  attributed_name        AS "Staff",
  attributed_email       AS "Email",
  end_of_quarter_balance AS "End-of-quarter balance",
  quarterly_interest     AS "Interest in quarter",
  interest_share         AS "Pre-split share",
  commission_multiple    AS "Multiple",
  commission_amount      AS "Commission"
FROM commission.vw_interest_attributions
WHERE 1 = 1
  [[ AND lower(attributed_email) = lower({{staff_email}}) ]]
  [[ AND fy_year     = {{fy_year}} ]]
  [[ AND quarter_num = {{quarter_num}} ]]
  [[ AND role        = {{role}} ]]
ORDER BY quarter_end_in DESC, account_id, role;
