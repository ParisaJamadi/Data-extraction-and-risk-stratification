# Xantura — Data & Analytics Consultant: Take-Home Task

My response to the Xantura Data & Analytics Consultant interview task. It is **not a runnable
application** — it is a SQL extraction script plus a written approach document.

> No Python. **Part 1** is a SQL exercise (Microsoft SQL Server / MSSQL on Windows Server);
> **Part 2** asks for an *outline of an approach*, not working model code.

---

## The task

1. **Part 1 – Data Extraction:** Build the sample client database, analyse its data-quality
   problems, and write a SQL script that extracts the data into Xantura's pipe-delimited
   DACSV3 CSV format.
2. **Part 2 – Data Science:** Outline an approach to stratify frailty risk (Low/Med/High) for a
   UK local authority's 65+ population, using structured and unstructured data.

## Where to look

| File | What it is |
|---|---|
| **[`SOLUTION.md`](SOLUTION.md)** | The written explanation of **Part 1 and Part 2** — analysis, design decisions, field mapping, and the data-science approach. **Start here.** |
| **[`HOW_TO_RUN.md`](HOW_TO_RUN.md)** | Step-by-step, beginner-friendly guide to installing SQL Server and running Part 1. |
| `solution/DACS_EXTRACT.sql` | **Part 1 deliverable** — profile + extract (run this in SSMS). |
| `solution/DACS_EXPORT_CSV.sql` | Renders the physical pipe-delimited CSV via `sqlcmd`. |
| `solution/MyOrg_09062026_DACSV3.csv` | Example of the generated output file. |
| `DACS_SETUP.txt` / `DACS_INSERT.txt` | Provided sample database (create + populate). |

> `DACS_SETUP.txt` / `DACS_INSERT.txt` contain only the small synthetic sample dataset supplied
> with the exercise (no real personal data).

---

## How to run Part 1 (quick version)

1. In SSMS, create a database (e.g. `DACS`).
2. Run `DACS_SETUP.txt` then `DACS_INSERT.txt` to build and populate it.
3. Run `solution/DACS_EXTRACT.sql` — Section 2 is the extract; Sections 1/3/4 show profiling,
   rejected rows and reconciliation. (Highlight Section 2 and press F5 to see just the extract.)

See **[`HOW_TO_RUN.md`](HOW_TO_RUN.md)** for the full walkthrough. *(Part 2 is a document —
nothing to execute.)*

---

## Key results at a glance

- **3 source rows → 2 extracted + 1 rejected** (a NULL mandatory DOB), fully reconciled.
- Handles the **UPN ambiguity**, **silent pence-loss** (`decimal(18,0)`), gender → **M/F/O/X**,
  NINO/address sentinels, and **PII + the pipe delimiter inside free-text case notes**
  (quote-escaped).
- **Deltas:** no modified-date column exists today, so full-only; recommends SQL Server
  **Change Tracking** with a watermark.
- **Part 2 frailty:** predict a **future adverse event (12 months)**, **LightGBM + Logistic
  Regression**, judged on **PR-AUC and recall at intervention capacity**, with SHAP + bias
  testing for fairness.
