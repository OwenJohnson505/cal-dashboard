# Questions for the Delivery Master vendor

Context for each question is included so the ask is self-contained. Nothing here
requires new development on their side unless marked — most of it is "tell us
what this field means" or "expose a field that already exists in the data model".

---

## 1. Special Price (Postcode Region) — what are the column headers?

`System Setup > Tariffs > Special Price > Postcode Region` shows the 800-row
regional pricing matrix (8 Regional tariffs × 10 UK regions × 10). After the
customer, tariff, from-region and to-region columns there are **two money
columns and a ratio column**. We need to know what the two money columns are.

Why it matters: the 8 Regional tariffs (Small Van / SWB / LWB / XLWB / Luton /
7.5T / 18T / 40FT Regional) carry no distance rate in the Tariffs grid, and
around a fifth of all open quotes sit on them. Until we know which column is
the customer charge we cannot price those quotes against tariff.

What we already tried: neither column matches actual job revenue on the same
lane (one is ~4× off, the other ~1.7×), and one of the two is constant per
origin region regardless of destination — so our best guesses are wrong.

**Ask: the exact column definitions for that grid, ideally with one worked
example (e.g. Luton Regional, Scotland → Midlands).**

## 2. Can `bIsManual` / `IsQuoteAmended` be exposed?

The quote/booking data model already contains a manual-price flag and an
amendment flag (`bIsManual`, `IsQuoteAmended`, plus
`SendQuoteAmendmentNotificationEmail` etc.). Neither appears in any report or
in the grid column chooser.

Why it matters: we can measure that a quote's price deviates from tariff, but
not **who caused it** — a system surcharge and a hand-typed override look
identical. These two flags are exactly that distinction, and they already
exist in the database.

**Ask: add "Manual Price" and "Quote Amended" as available columns in the
quote/booking grid column chooser, or as fields on the Quote Conversion /
Non-Converted Quotes reports.** (Small development ask.)

## 3. Is there a price-history / audit trail for quotes?

The Booking Updates report shows booking detail but no price history. If a
quote's price was edited after creation, we cannot see the original value.

**Ask: is the original system-calculated price stored anywhere (report, grid
column, or API), and if so how do we get at it?**

## 4. Documented API access

The client talks to `dms-core-api` / `dms-background-api` (Azure), which
server-side already has operations like `GetConsignmentLogReportDetails`,
`GetBookingHavingIssueReportDetails`, `GetBookingOtherChargeDetailsByBookingID`.
We currently automate the UI nightly to export reports; direct API access would
be faster, more reliable, and lighter on their servers than driving the app.

**Ask: documented access to the report/read endpoints plus a service token.**
Also worth raising: the API traffic appears to be plain **HTTP, not HTTPS** —
they should confirm and fix that regardless.

## 5. Report gaps (smaller asks, same conversation)

- **Cancelled Bookings report has no "issued by" column** — cancellations
  cannot be attributed to a person, which skews per-person conversion.
- **Non-Converted Quotes report carries no distance or postcodes** — lost
  quotes cannot be priced against tariff, which is the case that matters most
  (were we losing quotes because they were overpriced?).
- **"Include Auto Archived Quotations" defaults to OFF** on the Cancelled
  Bookings report — with it off, ~93% of cancelled quotes are silently
  excluded. Can the default be on, or the setting remembered per user?
- **Is there a tariff export?** There is no report for the tariff tables; we
  read them from the System Setup grids. A simple export (Tariffs, Special
  Prices, Distance Unit Rates) would remove that need.
