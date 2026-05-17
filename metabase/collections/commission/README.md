# Commission collection

This directory is the Git-synced target for the Metabase "Commission"
collection. Metabase Pro/Enterprise Version Control with Git writes
cards (questions) and dashboards into here as YAML on each export.

## First-time setup

1. Build the upstream views in the database (see
   [`../../sql/install.sql`](../../sql/install.sql)).
2. In Metabase Admin > Settings > Version Control, enable Git sync and
   point it at this repo. Set the collection root to
   `metabase/collections/commission`.
3. Create the cards listed below from the SQL templates in
   [`../../questions/`](../../questions/). The first sync from Metabase
   will write the canonical YAML for each card alongside this file.
4. Add the dashboard described in
   [`../../dashboards/commission-dashboard.md`](../../dashboards/commission-dashboard.md).

## Cards to create

| Card name                            | SQL template                                |
|--------------------------------------|---------------------------------------------|
| Commission - Quarterly Summary       | `questions/quarterly_summary.sql`           |
| Commission - Threshold Status        | `questions/threshold_status.sql`            |
| Commission - Fees attribution detail | `questions/fees_attribution_detail.sql`     |
| Commission - Interest detail         | `questions/interest_attribution_detail.sql` |
| Commission - Sales by role           | `questions/sales_by_role.sql`               |
| Commission - YTD by quarter          | `questions/ytd_commission.sql`              |

After the first export, edits made in Metabase land in this directory
as YAML and edits to the SQL files in `../../questions/` can be ported
manually (paste into the card editor) or via a script.
