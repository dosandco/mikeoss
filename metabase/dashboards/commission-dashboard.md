# Commission Dashboard

Layout spec for the staff-facing Commission dashboard. Reproduce these
in Metabase, then Git sync will export the canonical YAML alongside the
cards.

## Filters (dashboard parameters)

| Parameter      | Type   | Default                           | Maps to question variable |
|----------------|--------|-----------------------------------|---------------------------|
| Staff member   | text   | logged-in user's email (per user) | `{{staff_email}}`         |
| Fiscal year    | number | current FY                        | `{{fy_year}}`             |
| Quarter        | number | (none — show all)                 | `{{quarter_num}}`         |

To wire "Staff member" to the logged-in user, set the parameter's
default value to a JWT claim or, more simply, set sandbox attributes
per user under Admin > People > User attributes (e.g. `email`) and
reference `{{email}}`.

## Layout

```
┌───────────────────────────────────────────────────────────────────────────┐
│ Commission - Threshold Status (big number / gauge)                        │
│ Card SQL: threshold_status.sql                                            │
├───────────────────────────────────┬───────────────────────────────────────┤
│ Sales by attribution role         │ YTD commission by quarter             │
│ (pie or stacked bar)              │ (combo: bar = quarterly, line = cum.) │
│ Card SQL: sales_by_role.sql       │ Card SQL: ytd_commission.sql          │
├───────────────────────────────────┴───────────────────────────────────────┤
│ Commission - Quarterly Summary (table)                                    │
│ Card SQL: quarterly_summary.sql                                           │
├───────────────────────────────────────────────────────────────────────────┤
│ Commission - Fees attribution detail (table, collapsed by default)        │
│ Card SQL: fees_attribution_detail.sql                                     │
├───────────────────────────────────────────────────────────────────────────┤
│ Commission - Interest attribution detail (table, collapsed by default)    │
│ Card SQL: interest_attribution_detail.sql                                 │
└───────────────────────────────────────────────────────────────────────────┘
```

## Drill-through

- Click any row in **Quarterly Summary** → filter the two detail tables
  below by that quarter and (if pre-filtered) that staff member.
- Click a slice in **Sales by role** → filter both detail tables by
  that role.

## Recommended formatting

- All monetary columns: GBP, 2 dp, with negative values in red.
- `Threshold progress (%)` on **Threshold Status**: gauge with bands
  `0–50%` red, `50–100%` amber, `≥100%` green.
- `Threshold met?` boolean: green check / red cross icon.
