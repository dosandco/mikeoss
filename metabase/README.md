# Commission dashboard (Metabase + Supabase `dospay`)

Implementation of the DOS & Co. Ltd. Commission Plan (effective 1 July
2024) as a Metabase dashboard, with all calculation logic stored in
git-tracked SQL.

## Scope

- **Plan:** quarterly commission on Completed Sales and Completed
  Renewals, with a per-staff Commission Multiple and minimum quarterly
  sales threshold (Commission Plan clauses 5 and 8, Commission Letter).
- **Roles:** every transaction can be attributed up to three times to
  internal staff — Brought In / Relationship Managed / Supervised — and
  once to an external introducer, each at its own rate from
  `sys_commission_users`.
- **Interest commission:** add-on to the plan, sourced from the
  pre-split `dp_introduced_int` / `dp_managing_int` / `dp_supervising_int`
  columns on `int_quarterly`.

## Architecture

```
                              ┌───────────────────────────────────┐
                              │  Supabase project: dospay         │
                              │  schema: public                   │
                              │   - fees_transactions             │
                              │   - dp_account                    │
                              │   - int_quarterly                 │
                              │   - sys_commission_users          │
                              └────────────────┬──────────────────┘
                                               │
                              ┌────────────────▼──────────────────┐
                              │  schema: commission (this repo)   │
                              │   - dos_fy_quarter(date) fn       │
                              │   - vw_fees_attributions          │
                              │   - vw_interest_attributions      │
                              │   - vw_commission_quarterly       │
                              │  Source: metabase/sql/            │
                              └────────────────┬──────────────────┘
                                               │
                              ┌────────────────▼──────────────────┐
                              │  Metabase Native questions        │
                              │  Source: metabase/questions/      │
                              └────────────────┬──────────────────┘
                                               │
                              ┌────────────────▼──────────────────┐
                              │  Commission dashboard             │
                              │  Spec: metabase/dashboards/       │
                              │  Git sync target:                 │
                              │    metabase/collections/commission│
                              └───────────────────────────────────┘
```

Every "what does the commission formula say?" question is answered in
one place — the views under `metabase/sql/`. The Metabase questions
are thin `SELECT ... FROM commission.vw_...` wrappers, which keeps
the surface area for Metabase Git sync drift small.

## Layout of this directory

```
metabase/
├── README.md
├── sql/
│   ├── 01_calendar_function.sql
│   ├── 02_fees_attributions_view.sql
│   ├── 03_interest_attributions_view.sql
│   ├── 04_commission_quarterly_view.sql
│   └── install.sql                          # runs the above in order
├── questions/                               # Metabase Native SQL
│   ├── quarterly_summary.sql
│   ├── threshold_status.sql
│   ├── fees_attribution_detail.sql
│   ├── interest_attribution_detail.sql
│   ├── sales_by_role.sql
│   └── ytd_commission.sql
├── dashboards/
│   └── commission-dashboard.md              # layout + filter spec
└── collections/
    └── commission/                          # Metabase Git sync target
        ├── .collection.yml
        └── README.md
```

## Deploy

### 1. Apply the SQL to Supabase `dospay`

The views live in their own schema (`commission`) so they don't pollute
`public`. They are read-only and additive — no existing tables are
touched.

Option A — Supabase SQL Editor:

1. Open the `dospay` project (`dipuogwruqjrytblvvvp`) > SQL Editor.
2. Paste and run each file in `metabase/sql/` in numerical order. The
   `\ir` directive in `install.sql` is for `psql` only, so use the
   individual files from the SQL Editor.

Option B — `psql` against the pooler URL:

```bash
psql "$DOSPAY_DATABASE_URL" -f metabase/sql/install.sql
```

Then sanity-check:

```sql
SELECT * FROM commission.dos_fy_quarter(CURRENT_DATE);
SELECT * FROM commission.vw_commission_quarterly LIMIT 10;
```

### 2. Connect Metabase to `dospay`

If `dospay` isn't already a connected database in Metabase, add it
under Admin > Databases. Use a least-privileged role with read access
to the `public` and `commission` schemas (see the commented `GRANT`
block at the bottom of `install.sql`).

### 3. Create the cards and dashboard

Follow `metabase/collections/commission/README.md` to build each card
from its `.sql` template, then assemble the dashboard per
`metabase/dashboards/commission-dashboard.md`.

### 4. Enable Git sync

Metabase Pro / Enterprise: **Admin > Settings > Version Control**.
Point it at this repo, branch `claude/metabase-commission-dashboard-yvKW6`
(or whichever branch you settle on), with the collection root set to
`metabase/collections/commission`. From then on:

- Edit a card or dashboard in Metabase → it writes YAML into the
  collection directory on the next export, which you commit.
- Edit a `.sql` view file in this repo → re-run the relevant file in
  the database and the dashboard picks up the change without touching
  Metabase.

## Pete's worked example (sanity check)

Per the Commission Letter (5 Aug 2024):

| Field                     | Value      |
|---------------------------|------------|
| Brought In rate           | 7%         |
| Managed rate              | 2%         |
| Supervised rate           | 1%         |
| Introducer rate           | 0%         |
| Commission Multiple       | 0.50       |
| Min quarterly threshold   | £15,875.00 |

If Pete is the `dp_introduced`, `dp_managing` and `dp_supervising` on
every transaction (which he is in the current `dp_account` rows), then
his per-line commission rate is `(7% + 2% + 1%) × 0.50 = 5%` of net.
At the £15,875 threshold, his minimum qualifying commission is
`£15,875 × 5% = £793.75` per quarter.

## Open data gaps

These don't block dashboard scaffolding but they will keep numbers at
zero on the live data until addressed.

1. **`fees_transactions.date` is NULL on all 76 rows.** The Relevant
   Date is the date the fee was received in full. Until that column is
   populated, the views fall back to `created_at` so rows still show
   up. Backfill `date` with the real receipt date as soon as it's
   available.
2. **`fees_transactions.dp_account` is NULL on all 76 rows.** Without
   the link to `dp_account`, no transaction can be attributed to a
   staff member, so the fees commission column is £0. Populate
   `dp_account` on each existing and new row.
3. **No New Business vs Renewal flag.** The plan distinguishes them at
   potentially different rates (clause 5.1.b). Pete's letter sets both
   equal so this doesn't matter for him today; for other staff it
   might. When the data captures the distinction (e.g. an `is_renewal`
   column or a tracking_category convention), update the
   `business_type` CASE in `02_fees_attributions_view.sql` and split
   the `commission_rate` lookup into `new_business_*` vs `renewal_*`
   columns on `sys_commission_users`.
4. **Q2 quarter-end.** Plan clause 8.1 says Q2 ends "30th May" — every
   other quarter end is the last day of its month, so this is either a
   plan typo or a deliberate one-day cutoff. The calendar function
   honours the plan text (30 May). If you confirm it's a typo, edit
   `commission.dos_fy_quarter` to use `make_date(fy_year, 5, 31)`.
5. **Payroll day of month.** Plan says "the usual payroll date in the
   second calendar month following the end of the quarter" without
   pinning a day. The function uses the 28th of the payroll month to
   stay calendar-safe; change it to your real pay day if needed.

## Plan features not yet modelled

These are explicitly out of scope for the dashboard and handled
operationally; flagging here for completeness.

- **Split commissions (clause 7).** The current model assumes the
  three staff slots on `dp_account` already capture the split. If a
  single role needs to be split between two people (e.g. two
  Relationship Managers), that needs a new attribution table —
  doable but adds complexity.
- **Clawback (clause 10).** Cancellations, defaults and adjustments
  require negative entries against the same `(journal_line_id,
  attributed_email, role)` tuple. The views aggregate signed
  `net_amount` so negative correction rows in `fees_transactions`
  will flow through automatically.
- **Termination / leavers (clause 11).** No effective-date field on
  `sys_commission_users` today; if you need rate history (rates
  changing partway through a quarter), add `valid_from` / `valid_to`
  columns and join on the transaction's relevant date falling in the
  range.
- **Special projects (clause 6).** These are bespoke and excluded
  from the standard calculation.

## Verifying numbers

A handy spot-check query for one staff member, one quarter:

```sql
SELECT
  cq.*,
  (SELECT COUNT(*) FROM commission.vw_fees_attributions f
    WHERE f.attributed_email = cq.attributed_email
      AND f.fy_year = cq.fy_year AND f.quarter_num = cq.quarter_num)
                                                AS fees_lines,
  (SELECT COUNT(*) FROM commission.vw_interest_attributions i
    WHERE i.attributed_email = cq.attributed_email
      AND i.fy_year = cq.fy_year AND i.quarter_num = cq.quarter_num)
                                                AS interest_lines
FROM commission.vw_commission_quarterly cq
WHERE cq.attributed_email = 'ph@dosandco.com'
ORDER BY cq.fy_year DESC, cq.quarter_num DESC;
```
