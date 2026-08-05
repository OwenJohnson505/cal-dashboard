# Delivery Master → Supabase pipeline

Delivery Master has no API, no CLI and no report scheduler. Reports are rendered
locally by the desktop app into `Reports\<ReportType>\`. These three scripts turn
that into an unattended nightly pipeline.

| Script | Does |
|---|---|
| `dm_auto.ps1` | Drives the Delivery Master UI via Windows UI Automation to export reports |
| `dm_ingest.py` | Reads the newest export of each report and upserts it into Supabase |
| `dm_nightly.ps1` | Runs both of the above, then emails a summary with the exports attached |

---

## First-time setup

### 1. Store the two logins (do this once)

Both profiles are needed — they have different passwords.

```powershell
cd C:\Users\jowen\Repos\cal-dashboard\tools
.\dm_auto.ps1 -StoreCredential CalNorth
.\dm_auto.ps1 -StoreCredential CalSouth
```

Each prompts with the standard Windows credential dialog. The password goes
straight into **Windows Credential Manager** under `DeliveryMaster/CalNorth` and
`DeliveryMaster/CalSouth`. It is never printed, logged, or written to a file, and
never appears on a command line.

`CalNorth` maps to the dropdown entry **"Default"** and `CalSouth` to **"Cal South"**.
The dropdown has exactly four entries, read off the live control: **Default**,
**Cal Manchester**, **Cal Runcorn**, **Cal South**. There is no "CalSafe". If those display names are wrong, fix
`$Script:ProfileDisplayName` at the top of `dm_auto.ps1`.

You can also add them through the Credential Manager GUI, but the target name
must match exactly, so the command above is safer.

To check what is stored: `cmdkey /list | findstr DeliveryMaster`

### 2. Set the Supabase key (once, for the ingest step)

```powershell
[Environment]::SetEnvironmentVariable('SUPABASE_SERVICE_KEY','<your service key>','User')
```

---

## Before trusting it: map the UI

The report tiles have not been mapped yet — the app closed on its idle timeout
before that could be done. Run this first; it logs in and dumps the accessibility
tree to `dm_tree_<timestamp>.txt`:

```powershell
.\dm_auto.ps1 -Discover -Profile CalNorth
```

Then check the tile names in `$Script:ReportPlan` against that tree. The plan
currently assumes the headings visible in the UI (`Booking Issues`,
`Response Time`, `Productivity Summary Report`, `Driver Allocation by User`,
`Consignment Log`, `User Login`, `Driver List`, `Customer List`).

---

## Running it

```powershell
.\dm_auto.ps1 -Run -Profile CalNorth,CalSouth          # exports only, yesterday
.\dm_auto.ps1 -Run -Profile CalNorth -From 2026-08-01 -To 2026-08-01
.\dm_nightly.ps1 -SkipEmail                           # export + ingest, no email
.\dm_nightly.ps1                                      # the full nightly run
```

Install the 10pm schedule **only once a manual run has worked end to end**:

```powershell
.\dm_nightly.ps1 -RegisterSchedule
```

Remove it with:

```powershell
Unregister-ScheduledTask -TaskName 'Cal - Delivery Master nightly reports'
```

---

## Things that will bite

**The 15-minute idle timeout is real.** Delivery Master shuts itself down after
about 15 minutes of no activity — it did exactly that mid-session while this was
being built. `dm_auto.ps1` therefore re-establishes the session before *every*
report rather than assuming one login covers the run. Expect a nightly run to log
in several times; that is intended, not a fault.

**The date boxes ignore typed input.** They are segmented masked controls;
sending keystrokes does nothing (verified). The script sets them through the
UI Automation `ValuePattern` instead. If a future version of the app breaks that,
the fallback is the calendar picker — not typing.

**The task runs in the interactive session.** UI automation needs a real desktop,
so the scheduled task only fires when Owen is logged in. It is set to
`-StartWhenAvailable -WakeToRun`, so a missed run catches up.

**Report run times vary a lot.** Booking Issues took ~10 seconds, Response Time
about 90. The script waits for a new file to appear (up to 10 minutes per report)
rather than sleeping a fixed amount.

**Failures leave a modal open.** If a report fails, the script force-closes
Delivery Master so the next report starts from a known state.

---

## Known-good report parameters

From driving the UI manually on 2026-08-05:

- Reports tab → group (Customer / Driver / Booking / Account Reports /
  Account Exports / Other) → each tile has a **Process** button.
- Process opens a **Search Criteria** dialog: customer dropdown plus an **All**
  checkbox, a From/To date range, and on some reports extra radio groups
  (Live/Archived/Both, Ongoing/Resolved/Both).
- **Export** starts it; "Please wait while processing" shows; the file lands in
  `Reports\<Type>\` and auto-opens in Excel.

Booking Reports holds most of what matters: Booking Issues, Response Time,
Productivity Report, Productivity Summary Report, Driver Allocation by User,
User Login (staff work time), Customer Data, Gross Margin, Consignment Log,
Monthly Comparison and Tariff based Income.
