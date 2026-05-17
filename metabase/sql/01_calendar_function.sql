-- DOS & Co. fiscal-quarter calendar.
--
-- Maps any date to the fiscal year, quarter, quarter start/end and the
-- payroll date on which commission for that quarter is due, per the
-- Commission Plan effective 1 July 2024.
--
-- Plan reference (clause 8.1):
--   Q1 ends 28th February  -> April payroll
--   Q2 ends 30th May       -> July payroll   [NB: plan text uses 30 May,
--                                              not 31 May. Honoured here.]
--   Q3 ends 31st August    -> October payroll
--   Q4 ends 30th November  -> January payroll (following calendar year)
--
-- A DOS fiscal year ending 30 November YYYY spans 1 Dec (YYYY-1) -> 30 Nov YYYY.
-- For a date d:
--   fy_year   = year of d if month != Dec, else year of d + 1
--   quarter   = 1 (Dec/Jan/Feb), 2 (Mar/Apr/May), 3 (Jun/Jul/Aug), 4 (Sep/Oct/Nov)
--
-- Payroll date: paid on the usual payroll date in the second calendar month
-- following the end of the quarter. Day-of-month for payroll is set to the
-- 28th here so the value is calendar-safe (every month has a 28th). Adjust
-- to your real payroll day-of-month if you run a fixed pay date.

CREATE SCHEMA IF NOT EXISTS commission;

CREATE OR REPLACE FUNCTION commission.dos_fy_quarter(d date)
RETURNS TABLE (
  fy_year       integer,
  quarter_num   integer,
  quarter_label text,
  quarter_start date,
  quarter_end   date,
  payroll_date  date
)
LANGUAGE sql
IMMUTABLE
AS $$
  WITH base AS (
    SELECT
      CASE WHEN EXTRACT(MONTH FROM d) = 12
           THEN EXTRACT(YEAR FROM d)::int + 1
           ELSE EXTRACT(YEAR FROM d)::int
      END AS fy_year,
      CASE
        WHEN EXTRACT(MONTH FROM d) IN (12, 1, 2) THEN 1
        WHEN EXTRACT(MONTH FROM d) IN (3, 4, 5)  THEN 2
        WHEN EXTRACT(MONTH FROM d) IN (6, 7, 8)  THEN 3
        ELSE 4
      END AS quarter_num
  )
  SELECT
    fy_year,
    quarter_num,
    'FY' || fy_year || '-Q' || quarter_num AS quarter_label,
    CASE quarter_num
      WHEN 1 THEN make_date(fy_year - 1, 12, 1)
      WHEN 2 THEN make_date(fy_year,      3, 1)
      WHEN 3 THEN make_date(fy_year,      6, 1)
      WHEN 4 THEN make_date(fy_year,      9, 1)
    END AS quarter_start,
    CASE quarter_num
      WHEN 1 THEN (make_date(fy_year, 3, 1) - INTERVAL '1 day')::date
      WHEN 2 THEN make_date(fy_year, 5, 30)
      WHEN 3 THEN make_date(fy_year, 8, 31)
      WHEN 4 THEN make_date(fy_year, 11, 30)
    END AS quarter_end,
    CASE quarter_num
      WHEN 1 THEN make_date(fy_year,     4,  28)
      WHEN 2 THEN make_date(fy_year,     7,  28)
      WHEN 3 THEN make_date(fy_year,    10,  28)
      WHEN 4 THEN make_date(fy_year + 1, 1,  28)
    END AS payroll_date
  FROM base;
$$;

COMMENT ON FUNCTION commission.dos_fy_quarter(date)
  IS 'Maps a date to the DOS & Co. fiscal quarter (FY ends 30 Nov) per the Commission Plan clause 8.1.';
