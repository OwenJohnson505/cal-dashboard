# Outstanding data issues — resolve at the data refresh

Deliberately **not** fixed yet. Owen's call (2026-08-06): finish deciding what the
dashboard should measure first, then change the data points and reload everything
in one pass rather than patching piecemeal.

Each item below says what is wrong, how it was proved, and what fixing it involves.

---

## 1. Blocking — numbers are wrong until these are fixed

### 1.1 Cancelled quotes are ~93% missing
The Cancelled Bookings report has an **"Include Auto Archived Quotations"**
checkbox that **defaults to OFF**. Every historical upload was made with it off,
so auto-archived quotations — dead quotes the system sweeps up, all of them
losses — were never loaded.

Measured on July 2026, Cal North:

| | Supabase | Fresh export (box ticked) |
|---|---|---|
| converted | 1,122 | — |
| non-converted | 996 | 973 ✓ |
| cancelled (Q refs) | **67** | **944** ✗ |

True rate `1,122 / (1,122 + 973 + 944)` = **36.9%**. Dashboard shows ~53%.
The three files share **zero** references, so this is a missing category, not
double counting.

**Fix:** re-export Cancelled Bookings with the box ticked and reload. Two
constraints: all-dates + auto-archived ran >25 min without finishing, so do it
**month by month**; and clear the existing rows for each month first or the
append-only uploader will duplicate them.

### 1.2 Quote Conversion is keyed on the wrong date
The report's date filter is **Quote Booked On**. Ingest derives `week_label`
from **Quote Created On**. So a quote created in June and booked in July sits in
June's cohort while its win lands in July's export — inflating conversion in any
week that booked more than it created.

**Fix:** decide which date defines a cohort (creation is the honest one for
conversion) and make export filter and `week_label` agree.

### 1.3 Uploads append with no de-duplication
No upsert anywhere. Re-uploading an overlapping period duplicates rows.

| table | rows | distinct refs | duplicates |
|---|---|---|---|
| converted_quotes | 6,256 | 3,875 | **2,381 (38%)** |
| non_converted_quotes | 3,982 | 3,367 | 615 |
| cancelled_quotes (Q) | 658 | 553 | 105 |

1,232 of 1,277 duplicated refs are byte-identical re-uploads spanning multiple
source files. `jobs` has the same exposure on `job_no`.

**Fix:** unique constraint + upsert on the natural key for each table
(`our_ref`, `quote_no`, `job_no`).

### 1.4 Evri multi-driver rows distort group profit
`Evri Limited Enfield`: 29 jobs, £236k revenue against £513k cost = **-£277k**.
Across all Evri entities roughly **-£325k**, W17-2025 to W03-2026. Cause:
`call_sign` and `supplier` hold several newline-separated drivers and the cost
sums every driver against one job's revenue.

**Fix:** decide whether these are a data artefact (split the cost) or a real
loss. Either way group profit is currently wrong by about a third of a million.

---

## 2. Fields that need normalising before their tabs mean anything

- **`vehicle` — 248 distinct values.** Tariff names mixed with vehicle types
  ("Small Van", "Small Van Dedicated", "Small Van OOH", "LWB WD £350",
  "Wincanton Luton Remedials Octopus"). Needs a vehicle-type field separate from
  tariff.
- **`supplier` — 9,240 distinct values.** Holds driver names, not companies.
  DM's **DriverList** report gives the authoritative `Type`
  (Contract 314 / CX 446 / Other 22) keyed on call sign — load it and join.
- **Quote issuer names live in two namespaces** (`KS` vs `KyleS`). Currently
  patched by a hardcoded `ISSUER_ALIAS` map in `management.html`; belongs in an
  alias table like `rep_aliases`.
- **Sales rep strings — 43 values** including "Jodie 2026", "Jodie & Max",
  "Max (Nicola Lapsed)", "Old Contact", "north customer". Partly covered by
  `rep_aliases`; needs finishing.

---

## 3. Data we are not capturing at all

The consignment log has **45 columns; ingest captures 16.** Missing and valuable:

| Column | Unlocks |
|---|---|
| POB Arrived At, POD Arrived At | dwell time at collection and delivery |
| Collecting By | collection deadline → collection punctuality |
| Waiting Time (Mins) | a direct billable cost driver |
| Invoice Number, Supplier Invoice Number | reconciliation to Xero, credit control |
| Booked By | ops workload by person |
| Items, Weight | pricing by volume/weight |
| PU Company Name, Deliver To, Town | true lane analysis (only postcodes today) |
| Fuel Charge | cost breakdown |

Coverage gaps in what *is* captured: ~25% of jobs have no `booked_at` or
`delivery_deadline`, ~30% no mileage, ~29% no POB. **On-time performance is
unmeasurable for a quarter of the book**, and there is no job-status or
failure-reason field at all — a failed delivery is indistinguishable from a
successful one.

**Also not yet ingested:** Booking Issues and Response Time are exported nightly
but have no staging tables or parsers, so service quality and allocation speed
are absent from the dashboard entirely.

---

## 4. Security and access — decisions still open

- **Depot isolation does not work.** `authenticated_select USING(true)` ORs with
  `depot_select`, so the 1 north and 3 south non-admin users see everything.
  Proved by simulating their sessions. Decide: enforce depots, or drop the
  depot policies as dead weight.
- **Public signup is still enabled** (`disable_signup: false`) with
  auto-confirm. Defanged — a profile-less account sees zero rows — but strangers
  can still create accounts. Admin "Add User" no longer needs it, so it can be
  switched off in the Supabase Auth UI.
- **Leaked-password protection is off.** One toggle.
- **`nest_boards` is public read+write** by design (the Nest app has no login).
  No company data, but worth a decision.
- **Backups:** confirm point-in-time recovery is on. For months the data was
  deletable by anyone.

---

## 5. Pipeline gaps

- **`SUPABASE_SERVICE_KEY` is not set on the machine**, so the nightly ingest
  step fails every night. Reports arrive by email but never reach the database.
  `[Environment]::SetEnvironmentVariable('SUPABASE_SERVICE_KEY','…','User')`
- **Ten DM reports are not yet automatable.** Several were victims of the
  output-watcher bug fixed in 770d56a and probably work now — Customer List was
  retested and does (54s). Retest: User Login, Driver List, Aged Debtors,
  Dashboard Report, Quote Conversion, Non-Converted Quotes, Cancelled Bookings,
  Gross Margin, Customer Data.
- **The Cancelled Bookings dialog needs special handling** in `dm_auto.ps1`: it
  uses `dpDateFrom`/`dpDateTo` (not `dDateFrom`), and the date fields stay
  **disabled until "All Dates" (`chkAll`) is genuinely clicked** — a
  programmatic TogglePattern toggle does not enable them.
- **Vendor API.** Delivery Master has server-side report operations
  (`GetConsignmentLogReportDetails`, `GetBookingHavingIssueReportDetails`, …)
  behind `dms-background-api.azurewebsites.net`. Owen has the vendor
  relationship; documented access plus a service token would retire the UI
  automation entirely. Note the API is plain **HTTP**, not HTTPS.

---

## 6. Tariff pricing — one table decoded, one blocked

20 of 500 tariffs carry **no distance rate** (base/included/rate all zero) and cover
**~24% of quotes**, so they cannot be priced from the Tariffs grid. Their pricing
lives in `System Setup > Special Price`, which turned out to be fully scrapeable
(previously recorded as a per-customer modal — that was wrong).

| quote bucket | share | status |
|---|---|---|
| priced from the rate card | 76.0% | working |
| zero-rate → **Postcode** table | 3.0% | **solved** |
| zero-rate → **Region** matrix | 20.7% | **blocked** |
| zero-rate, no table found | 0.3% | open |

**Solved — postcode mode** (5,220 rows, 27 customers, 54 tariffs). Column `v4` is the
customer charge, validated against real jobs: 7 of 19 shared depot lanes match to the
penny, median difference £0.00. Scrape: `tools/special_prices_postcode_CalNorth.csv`.

**Blocked — region mode** (800 rows = 8 Regional tariffs × 10 × 10 UK regions). The
grid exposes **no column headers** to UI Automation and the WPF surface will not screen-
capture, so the two money columns are unidentified. Neither predicts actual revenue
across 2,080 mapped jobs (0% and 2% exact; medians 4.0× and 1.71×). Reading them as
price/cost implies −287% margin on 18T, so that reading is wrong.
**Action: get the column headers from the vendor, or read them off the screen by hand.**
Until then this table must not be used — it is the single biggest remaining gap in
pricing attribution.

Also confirmed dead ends: **Zone Price is unused** (no zones configured at all), and the
**"Test Distance Rates" calculator** on the Distance Unit Rate screen is exact but only
covers the 4 "NW Dynamic" tariffs, not Regional.

---

## 7. Analytical limits to remember

- **Reps own their customers**, so no two work the same accounts. Standardising
  margin on (customer × vehicle) returns nothing; vehicle/tariff is the only
  shared comparator. This caps how precisely sales performance can be judged.
- **Any conversion figure before March 2026 is meaningless** — the Non-Converted
  report does not exist in the data before then, so those periods compare won
  against cancelled only.
- **Cancellations cannot be attributed to a person.** The Cancelled Bookings
  report has no "issued by" column, so per-person conversion necessarily
  excludes them and reads high against the company rate.
