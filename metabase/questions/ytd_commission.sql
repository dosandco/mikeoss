-- Metabase question: Commission - Year-to-date by quarter
--
-- For chart: line / bar with quarter on X-axis. Shows commission earned
-- each quarter of the selected fiscal year for the selected staff
-- member, plus the cumulative running total.
--
-- Parameters:
--   {{staff_email}} text   optional
--   {{fy_year}}     number optional - if omitted, all FYs are returned
--                                   so chart consumers can default in
--                                   the dashboard filter

SELECT
  cq.fy_year                                        AS "FY",
  cq.quarter_label                                  AS "Quarter",
  cq.quarter_num                                    AS "Quarter #",
  cq.quarter_end                                    AS "Quarter end",
  cq.payroll_date                                   AS "Payroll date",
  cq.attributed_sales_gross                         AS "Attributed sales",
  cq.commission_fees_total                          AS "Fees commission",
  cq.commission_interest_total                      AS "Interest commission",
  cq.commission_total                               AS "Total commission",
  SUM(cq.commission_total) OVER (
    PARTITION BY cq.attributed_email, cq.fy_year
    ORDER BY cq.quarter_num
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  )                                                 AS "Cumulative FY commission",
  cq.threshold_met                                  AS "Threshold met?"
FROM commission.vw_commission_quarterly cq
WHERE 1 = 1
  [[ AND lower(cq.attributed_email) = lower({{staff_email}}) ]]
  [[ AND cq.fy_year = {{fy_year}} ]]
ORDER BY cq.fy_year, cq.quarter_num;
