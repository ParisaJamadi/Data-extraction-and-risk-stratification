# How to Set Up, Run and Check the DACS Extract — Beginner's Guide

A complete, plain-English walkthrough of everything from installing SQL Server to producing
and checking the extract. Written for someone new to SQL Server. Follow it top to bottom.

---

## 0. What is this task (in plain English)?

Xantura's product **OneView** needs client data loaded into it. The first job is to **extract**
the data out of the client's database into an **agreed file format** (a CSV described in the
"DACS Test - File Specification").

So the task is:
1. Build a small example database (scripts are provided).
2. Look at the data and spot the problems (bad dates, weird formats, ambiguous fields...).
3. Write **one SQL script** that pulls the data out into the **12 fields** the spec asks for,
   in the right order and format.

Our finished SQL script is **`solution/DACS_EXTRACT.sql`** 

---

## 1. What you need to install (and why)

| Tool | What it is | Why |
|---|---|---|
| **SQL Server Express** | The free database engine from Microsoft | Stores the data and runs SQL. The brief says "assume MSSQL". |
| **SSMS** (SQL Server Management Studio) | A free app with a window to type SQL and see results | This is how you actually run the scripts. |

Download both by searching **"SQL Server Express download"** and **"SSMS download"**.
- Install **SQL Server Express** → choose **Basic**. When done it shows your **instance name**
  (`SQLEXPRESS`), so your server is **`localhost\SQLEXPRESS`**.
- Install **SSMS** → you don't need any optional "workloads"; the core components are enough.
- When SSMS asks you to sign in, you can click **"Skip and add accounts later"** — not needed.

---

## 2. Connect to your database server

1. Open **SSMS**.
2. In the **Connect to Server** box:
   - **Server name:** `localhost\SQLEXPRESS`
   - **Authentication:** Windows Authentication
   - Tick **Trust Server Certificate** *(needed on a local PC, or you get an SSL error)*.
3. Click **Connect**. You'll see **Object Explorer** on the left with your server listed.

> **If you get a red "certificate chain... not trusted" error:** that's the missing tick above.
> Click OK, tick **Trust Server Certificate**, Connect again.

---

## 3. Create the database

1. Click **New Query** (toolbar).
2. Type this and press **F5** (or click **Execute**):

```sql
CREATE DATABASE DACS;
```

3. In the toolbar there is a **database dropdown** (it says `master`). Change it to **`DACS`**.
   - If `DACS` isn't listed: right-click **Databases** in Object Explorer → **Refresh**.

> **Golden rule:** before running ANY script below, always check that dropdown says **`DACS`**.

---

## 4. Build the tables and load the data

The two provided files are SQL saved as `.txt`. The easy way to run them is **copy-paste into
your already-connected query window**:

**4a. Create the tables**
1. Open `DACS_SETUP.txt` from the repo folder (File → Open → File).
2. Select all (**Ctrl+A**), copy (**Ctrl+C**).
3. Go to your connected query tab, select all (**Ctrl+A**), delete, paste (**Ctrl+V**).
4. Dropdown = `DACS` → **F5**. You should see *"Commands completed successfully"*.

**4b. Load the sample data**
1. Open `DACS_INSERT.txt` from the repo folder, copy all.
2. Paste into the query tab (clear it first), dropdown = `DACS` → **F5**.

> **If you see red "Cannot insert duplicate key" errors:** the data was already loaded once.
> Just re-run the **DACS_SETUP** script (it empties and recreates the tables), then run
> **DACS_INSERT** again exactly once.

**4c. Quick sanity check** — paste and run:

```sql
SELECT COUNT(*) AS people FROM dbo.DACS_PERSON;
SELECT COUNT(*) AS dependents FROM dbo.DACS_DEPENDENTS;
```
Expected: **people = 3**, **dependents = 3**.

---

## 5. Run the extract (the main event)

1. Open `solution\DACS_EXTRACT.sql` from the repo folder, copy all.
2. Paste into the query tab (clear it first), dropdown = `DACS` → **F5**.

You will get **several result grids** stacked in the Results pane (scroll down). They are:
- **Section 1 – profiling:** lists the data-quality problems (NULL DOB, suspect NINOs,
  money rounding, address issues).
- **Section 2 – the extract:** the 12-field output. **2 rows** (Trevor and Stephen).
- **Section 3 – rejects:** Rachael, reason "DOB missing (mandatory)".
- **Section 4 – reconciliation:** `source = 3`, `expected = 2`, `rejected = 1` → it balances.

That's success. No red errors should appear.

### What the result proves
- Middle names joined, address joined, NINO spaces stripped, DOB shown as `dd/MM/yyyy`,
  gender coded to M/F/O/X, dependents counted, and the bad row safely rejected.

---

## 6. (Optional) Save the extract as the real .csv file

The grid is fine for checking, but the spec wants an actual **pipe-delimited CSV file**.
We do this with **`sqlcmd`** (a command-line tool installed with SQL Server).

1. Open **PowerShell** (search "PowerShell" in the Start menu).
2. `cd` into the repo folder (the one containing this guide), e.g. `cd "C:\path\to\this-repo"`.
3. Paste this **one command** (paths are relative to the repo root) and press Enter:

```powershell
sqlcmd -S localhost\SQLEXPRESS -d DACS -E -C -h -1 -W -f 65001 -i ".\solution\DACS_EXPORT_CSV.sql" -o ".\solution\MyOrg_09062026_DACSV3.csv"
```

4. It finishes silently. Open **`solution\MyOrg_09062026_DACSV3.csv`** to see the result:

```
UPN|First Name|Middle Names|Surname|Address|NINO|DOB|Case Notes|Arrears|Credit|Number of Dependents|Gender
5678|Trevor|Ernest|Bayliss|54 Last lane, Trompington, Gravesham, Kent, GR39JL|MN8987Y|14/08/1964|"First meeting went well, ... Mel Griffiths | Mob :0787978797 | Email: mel@gov.org"||35.00|2|M
9182|Stephen|Jeremy Thomas|Jones|1 The View, Saddlers Wells|LK8965D|07/03/1972|Tried to Telephone, no answer. Wil try again in a few days|0.00|0.00|1|X
```

Notice Trevor's case note is wrapped in **double quotes** because it contains the `|` delimiter —
that's the escaping the spec requires.

> The file `DACS_EXPORT_CSV.sql` is a self-contained version of the extract that outputs one
> finished line per row (it creates a tiny helper function to do the quoting). You only need
> this if you want the physical file; the primary deliverable is `DACS_EXTRACT.sql`.

---


## 7. File map (what's what)

| File | What it is |
|---|---|
| `DACS_SETUP.txt` / `DACS_INSERT.txt` | Provided by Xantura — create + fill the example DB |
| `solution/DACS_EXTRACT.sql` | **The Part 1 deliverable** — analyse + extract (run this in SSMS) |
| `solution/DACS_EXPORT_CSV.sql` | Optional — produces the physical pipe-delimited file via sqlcmd |
| `solution/MyOrg_09062026_DACSV3.csv` | The generated output file (example) |
| `SOLUTION.md` | **The written explanation of Part 1 and Part 2** (analysis, design, data-science approach) |

---

## 8. One-line summary of what this does

> The example database is built from the supplied scripts, profiled to find the data-quality
> issues, then a set-based extract outputs the 12 spec fields as a pipe-delimited,
> quote-escaped CSV. It rejects the row that breaches the mandatory-DOB rule and reconciles
> 3 source = 2 extracted + 1 rejected.
