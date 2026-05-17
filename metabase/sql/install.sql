-- Idempotent installer for the commission schema.
-- Run in the Supabase SQL editor (project: dospay) or via psql:
--   psql "$DATABASE_URL" -f metabase/sql/install.sql
--
-- Order matters: the function is referenced by the views.

\ir 01_calendar_function.sql
\ir 02_fees_attributions_view.sql
\ir 03_interest_attributions_view.sql
\ir 04_commission_quarterly_view.sql

-- Grant read access for the Metabase service role. Replace 'metabase_ro'
-- with whatever role Metabase connects as in your installation. Comment
-- the GRANTs out if you connect Metabase as a superuser.
-- GRANT USAGE  ON SCHEMA commission TO metabase_ro;
-- GRANT SELECT ON ALL TABLES IN SCHEMA commission TO metabase_ro;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA commission GRANT SELECT ON TABLES TO metabase_ro;
