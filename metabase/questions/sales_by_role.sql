-- Metabase question: Commission - Sales by attribution role
--
-- For chart: stacked bar / pie. Shows how a staff member's attributed
-- sales break down across Brought In / Managed / Supervised / Introducer
-- for the selected scope.
--
-- Parameters:
--   {{staff_email}} text   optional
--   {{fy_year}}     number optional
--   {{quarter_num}} number optional 1-4

SELECT
  role,
  COUNT(DISTINCT journal_line_id) AS "Lines",
  SUM(net_amount)                 AS "Net amount",
  SUM(commission_amount)          AS "Commission"
FROM commission.vw_fees_attributions
WHERE within_plan_period
  [[ AND lower(attributed_email) = lower({{staff_email}}) ]]
  [[ AND fy_year     = {{fy_year}} ]]
  [[ AND quarter_num = {{quarter_num}} ]]
GROUP BY role
ORDER BY
  CASE role
    WHEN 'brought_in' THEN 1
    WHEN 'managed'    THEN 2
    WHEN 'supervised' THEN 3
    WHEN 'introducer' THEN 4
    ELSE 5
  END;
