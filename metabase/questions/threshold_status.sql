-- Metabase question: Commission - Threshold Status (current quarter)
--
-- Visualization: big-number / progress bar / gauge.
--
-- Parameters:
--   {{staff_email}} text required for single-staff cards
--
-- Returns one row scoped to the current DOS fiscal quarter for the
-- given staff member, showing attributed sales vs threshold and the
-- percentage of the way there.

WITH q AS (
  SELECT * FROM commission.dos_fy_quarter(CURRENT_DATE)
)
SELECT
  q.quarter_label                            AS "Quarter",
  q.quarter_start                            AS "Quarter start",
  q.quarter_end                              AS "Quarter end",
  cq.attributed_sales_gross                  AS "Attributed sales",
  cq.min_threshold                           AS "Threshold",
  cq.threshold_shortfall                     AS "Shortfall",
  cq.threshold_met                           AS "Threshold met?",
  CASE
    WHEN COALESCE(cq.min_threshold, 0) = 0 THEN NULL
    ELSE round((cq.attributed_sales_gross / cq.min_threshold) * 100, 1)
  END                                        AS "Threshold progress (%)",
  cq.commission_total                        AS "Indicative commission to date"
FROM q
LEFT JOIN commission.vw_commission_quarterly cq
  ON  cq.fy_year     = q.fy_year
  AND cq.quarter_num = q.quarter_num
  AND lower(cq.attributed_email) = lower({{staff_email}});
