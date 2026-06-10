# Solution — Xantura Data & Analytics Consultant Task

Two parts: a **SQL data‑extraction pipeline** (Part 1) and a **frailty risk‑stratification approach** (Part 2).

**At a glance**

| | Part 1 — Data Extraction | Part 2 — Frailty Stratification |
|---|---|---|
| **Goal** | Lift client data into the agreed DACSV3 pipe‑delimited CSV | Flag 65+ residents at rising risk of frailty, early enough to act |
| **Deliverable** | `solution/DACS_EXTRACT.sql` (+ `DACS_EXPORT_CSV.sql`) | This approach document |
| **Headline result** | 3 source rows → **2 extracted + 1 rejected** (mandatory‑DOB breach), fully reconciled | Predict a **future adverse event (12m)**; **LightGBM + Logistic Regression**; judged on **PR‑AUC & recall at intervention capacity** |

---

# Part 1 — Data Extraction (DACS / DACSV3)

> **Headline:** I profiled the sample database, found the data‑quality landmines (an ambiguous UPN, silent pence‑loss, a missing mandatory DOB, free‑text PII *and* the delimiter inside case notes), then wrote a **set‑based** extract that outputs the 12 spec fields, **rejects** the row that breaches a mandatory rule, and **reconciles** source = extracted + rejected.

## 1. Why this extract matters (business terms)

Xantura is deploying **OneView** (a multi‑agency data‑sharing / risk‑stratification platform) for a UK local authority. Before any analytics or risk modelling can happen, the client's operational data has to be **lifted out of their back‑end systems** into a **contractually signed‑off file format** — the DACSV3 extract definition.

**This extract is the front door of the whole engagement.** If it is late, incomplete or wrong, every downstream product (matching, dashboards, risk models, case‑finding) inherits that error. The DACSV3 file is a **person‑level master extract** — one row per individual — carrying identity, contact, financial (arrears/credit) and free‑text case‑note information. It must be **repeatable, auditable, and production‑grade** because it runs in *Xantura's* environment (Windows Server + Microsoft SQL Server / MSSQL) on a schedule.

## 2. Data‑quality problems found (and why each matters)

The sample DB has five tables, all keyed on `person_id`: `DACS_PERSON` (1/person), `DACS_CASENOTES` (1/person), `DACS_ARREARS` (1/person), `DACS_ADDRESS` (1/person), and `DACS_DEPENDENTS` (**many**/person).

| Issue | Detail | Why it matters / action |
|---|---|---|
| **UPN ambiguity** *(headline)* | Spec field `UPN` = "unique **person** reference", mandatory. Source has **two** candidates: `PERSON.person_id` (non‑null, unique) and `ADDRESS.upn` (int, **nullable**, optional table). In the sample, person `1234`'s `upn=5678` equals another person's `person_id` — an **identifier‑namespace overlap**. | Map `UPN → ADDRESS.upn` (literal spec source), **reject NULL‑upn rows**, keep `person_id` as switchable fallback (`@UseAddressUpnAsUPN`), **flag at sign‑off**. |
| **Silent money loss** | `debt`/`credit`/`pending` are `decimal(18,**0**)` — cannot store pence. Inserted `34.99` is **silently rounded to 35** *before we read it*. | Source defect — raise with client; the extract can't recover lost precision. |
| **Mandatory DOB missing** | Person `9012` has `dob = NULL`; DOB is mandatory. | **Reject and report** the row (never fabricate). |
| **DOB is `datetime`** | Carries a spurious time component. | Format to `dd/MM/yyyy`. |
| **Non‑Unicode text** | Names/notes are `varchar`; output must be UTF‑8. | Risk of corruption on accented chars — recommend `nvarchar` at source. |
| **NINO inconsistencies** | `MN8987Y` (wrong length), `LK 89 65 D` (embedded spaces), `UNKNOWN` (sentinel). | Upper‑case, strip spaces, sentinel → blank; report invalids. |
| **Address sentinels** | `NO ADDRESS GIVEN`, missing postcode, `GR39JL` missing its space. | Drop sentinel, NULL‑safe concat; postcode spacing flagged (needs lookup). |
| **Gender free‑text** | Stored as `Male`/`Female`/`NULL`; spec wants coded **M/F/O/X**. | Map; NULL/unmapped → **X (Unknown)**. |
| **Newlines in case notes** | Person `9012` has a multi‑line note. | Strip CR/LF/tab — illegal in a one‑row‑per‑line CSV. |
| **PII + delimiter in free text** | Person `1234`'s note holds a worker's name, mobile & email **and a `|`**. | (1) GDPR data‑minimisation — should free‑text PII be exported at all? (2) `|` must be **quote‑escaped** or it breaks the CSV. |
| **Referential integrity** | `DACS_PERSON` has a meaningless **self‑referencing FK**; child rows are independent. | Remove the odd FK; use **LEFT JOINs** so no one is dropped. |
| **Performance** | `DACS_DEPENDENTS` is keyed on `id`, so `GROUP BY person_id` scans. | Add a non‑clustered index on `DACS_DEPENDENTS(person_id)`. |
| **No change tracking** | No `created`/`modified` columns or row versioning. | Only a **full** extract is possible today (see §5). |

## 3. Extraction approach (production‑grade)

1. **Profile first** (Section 1 of the script) — never extract blind; surface DQ issues every run.
2. **Set‑based CTE pipeline** — `dep` pre‑aggregates dependents; `src` projects the 12 fields with all transforms; final SELECT enforces mandatory rules. No cursors, no row‑by‑row.
3. **LEFT JOIN** person → casenotes/arrears/address + dependents aggregate, so no one is dropped.
4. **Reject set** (Section 3) — rows failing mandatory rules, with a reason ("reject row, report for manual fixing").
5. **Reconciliation** (Section 4) — control totals (counts, sum of debt/credit, dependent counts) logged per run.
6. **File rendering** (Section 5 / `DACS_EXPORT_CSV.sql`) — exact header, pipe delimiter, **quote‑escaping** of any field containing `|` or `"`, CR/LF stripped, UTF‑8. In production I'd use an **SSIS Flat File destination** over `bcp`/`sqlcmd` for better encoding + quoting control.
7. **Parameterised & idempotent** — prefix, period date and the UPN decision are parameters; re‑running produces the same file.

## 4. Field‑by‑field mapping

| # | Output field | Source | Transformation | Note |
|---|---|---|---|---|
| 1 | **UPN** | `ADDRESS.upn` | cast to text; **reject if NULL** | Literal spec source; `person_id` switchable fallback; namespace overlap flagged |
| 2 | First Name | `PERSON.[first name]` | trim | optional |
| 3 | Middle Names | `[second name]`+`[third name]` | NULL‑safe concat, single space | "Middle Names" = 2nd + 3rd combined |
| 4 | Surname | `PERSON.surname` | trim | optional |
| 5 | Address | `address line 1‑4` + `postcode` | comma‑join, skip NULLs, drop `NO ADDRESS GIVEN` | postcode spacing not auto‑corrected — flagged |
| 6 | NINO | `PERSON.NINO` | upper, strip spaces, `UNKNOWN`→blank | invalids reported, not auto‑rejected |
| 7 | **DOB** | `PERSON.dob` | format `dd/MM/yyyy` | **mandatory** → NULL ⇒ row rejected |
| 8 | Case Notes | `CASENOTES.[case notes]` | strip CR/LF/tab; quote if contains `\|`/`"` | PII‑in‑text flagged for client decision |
| 9 | Arrears | `ARREARS.debt` | cast decimal(18,2) | "Arrears" = `debt` |
| 10 | Credit | `ARREARS.credit` | cast decimal(18,2) | source already rounded to whole £ — flagged |
| 11 | Number of Dependents | `COUNT(DEPENDENTS)` | group by person, 0 if none | household dependents |
| 12 | Gender | `PERSON.gender` | map to **M/F/O/X** | `Male→M`, `Female→F`, NULL/unmapped → **X** |

> `ARREARS.pending` is **deliberately not extracted** — it has no target field in the spec. Worth a one‑line confirmation with the client.

## 5. Running it in production

**Delta / incremental.** *The honest position:* with no `created`/`modified` columns or row versioning, only a **full** extract is possible as delivered. Production options, best first:
- **Change Tracking (recommended)** — built‑in, low‑overhead, **captures deletes**; store a version watermark and pull only changed `person_id`s via `CHANGETABLE(CHANGES…, @last_version)`.
- **`rowversion` + watermark** — simple; **misses deletes**.
- **`LastModified` + triggers** — needs schema + trigger maintenance.
- **Snapshot diff via `HASHBYTES`** — heavier, but **zero source changes** (useful when the client won't alter their DB).

**Late‑arriving data.** Extract with a **lookback overlap** (watermark − N days) and make the downstream load **idempotent** (upsert keyed on UPN + period date).

**Failed runs.** Advance the watermark **only after** the file is generated, validated *and* delivered — failures are re‑runnable and never lose or double‑count data. Each run writes to an `ETL_RunLog`.

**Validation & reconciliation.** Structural checks (header, 12 fields, pipe delimiter, UTF‑8, no stray newlines); field rules (DOB present, gender ∈ {M,F,O,X}, money numeric, UPN non‑null + **unique**); reconciliation (`source = extracted + rejected`, sum of debt/credit source vs file, dependent totals).

**Scheduling (Windows + SQL Server).** Default to **SQL Server Agent** (native, built‑in history/alerts); write the file with **SSIS** rather than bare `bcp` (because case notes contain the `|` delimiter and SSIS handles quote‑escaping + UTF‑8); fall back to **Task Scheduler + PowerShell** on SQL Express (no Agent); and **Azure Data Factory** with a self‑hosted IR + SFTP once delivery moves to the cloud.

---

# Part 2 — Frailty Stratification for the 65+ Population

> **Headline:** Frame frailty as **predicting a future adverse event within 12 months** (not just confirming who is already frail), score monthly into **Low/Med/High** bands with per‑person reasons, judge it on **PR‑AUC and recall at the team's real intervention capacity**, and govern it with **SHAP explanations + bias testing** so it prioritises fairly and a professional always decides.

## 1. Problem framing

**Objective.** Identify residents aged 65+ at risk of *becoming* frail early enough to intervene — to cut avoidable emergency admissions, slow escalation into costly long‑term care, and protect independence. The value is in catching the **rising‑risk middle**, not just confirming who is already frail. Output: a **Low / Medium / High** band + the top reasons per person, refreshed monthly, delivered as prioritised work‑lists to community teams and a dashboard for commissioners.

**Architecture (feature engineering → scoring):**
```
Sources → Data Quality & person-matching → Point-in-time Feature Store
       → Label definition → Train/validate (temporal split) → Calibrate
       → Monthly batch scoring (band + SHAP reasons) → Monitoring (drift/fairness) → Retrain
```
Governance (Caldicott Guardian / DPO / DPIA) and **intervention capacity** sit on the critical path — there is no point finding people we cannot help.

**Data I would ideally use:** GP / primary care (long‑term conditions, polypharmacy, consultation trend — the basis of the eFI); hospital / SUS (emergency admissions, A&E, **falls**, length of stay — strong signal *and* the cost outcome); adult social care (assessments, reablement, care‑package escalation — use carefully, leakage risk); demographics (age, sex, **deprivation/IMD**, ethnicity — drivers *and* fairness anchors); **unstructured case notes** (falls, confusion, "not coping", carer strain); housing/isolation/telecare (living alone, lifeline alarms).

**How frailty is labelled.** No single ground truth, so I frame it as **predicting a future adverse event** — *emergency admission, fall, or care escalation within 12 months* — and use the **electronic Frailty Index (eFI)** and Clinical Frailty Scale as **corroborating features and validation anchors**, not the sole target. *Reasoning:* a predictive label tied to the cost outcome is actionable; labelling purely on past care decisions would just relearn the council's historic biases. Definition to be clinically signed off and kept configurable.

## 2. Modelling approach

**EDA:** quantify **missingness** and treat it as informative ("no GP record" ≠ healthy) with missingness flags, checking it doesn't correlate with deprivation; **outliers** (implausible ages, negative length‑of‑stay, duplicate persons); **class imbalance** (high‑frailty is single‑digit %); **correlation/redundancy** (polypharmacy ↔ condition count); **segmentation** by age band, deprivation decile, geography to confirm it works *across* groups.

**Build plan:**
1. **Assemble & match** to a single resident record (point‑in‑time correct — only data available *before* the prediction date, to avoid leakage).
2. **Define the label** (future adverse event within 12 months); agree clinically.
3. **Engineer features** (below) + missingness flags.
4. **Split temporally** — train earlier, validate/test later (mirrors live use).
5. **Baseline first** — regularised **Logistic Regression** (transparent benchmark).
6. **Primary model** — **LightGBM / XGBoost**; cross‑validate; handle imbalance via `class_weight`/`scale_pos_weight`.
7. **Calibrate** probabilities (Platt/isotonic) so bands are trustworthy.
8. **Set thresholds** to the team's real intervention capacity; output bands + per‑person SHAP reasons.
9. **Validate fairness** across deprivation/ethnicity/sex/age before release.

**Key features:** count of long‑term conditions & multimorbidity; **polypharmacy** (≥5/≥10 meds, anticholinergic burden); emergency admissions / A&E / **falls** in 6–12m; GP consultation frequency & trend; care‑package hours & escalation; age & **deprivation**; living‑alone / isolation; **NLP‑derived flags** (falls, confusion, "not coping", carer strain) from case notes.

**Model choice:**
- **Primary — LightGBM / XGBoost:** best on messy, missing, mixed tabular health data; handles non‑linearities and missingness natively; **SHAP** gives per‑resident explanations.
- **Secondary — Logistic Regression:** transparent odds ratios a GP/commissioner trusts, trivial to govern. *If the simple model is close, ship it — adoption beats a leaderboard.*

**Metrics (imbalanced cohort, so accuracy misleads):** **PR‑AUC** (primary); **recall @ the intervention‑capacity threshold** (of the truly at‑risk, how many did we catch within the visits we can actually do?); **precision @ that threshold** (controls alert fatigue); **calibration / Brier**. Ultimately validated on **real admissions avoided**, not AUC.

## 3. Monitoring and fine‑tuning

**Tracking after deployment:** **data drift** (PSI/KS on key features + missingness, e.g. a GP coding‑system change); **concept drift** (feature→frailty relationship shifts, e.g. post‑pandemic care patterns); **performance** (back‑test PR‑AUC/recall/precision once outcomes mature; control charts + alerting).

**When to retrain:** on a **schedule** (e.g. annually) **and** on **trigger** (drift breach, performance below threshold, data/policy change). Always temporal‑validate and require **human sign‑off** before promoting — never auto‑promote a model that decides about vulnerable people.

**Fairness & explainability:** **SHAP** (per‑resident + global) alongside logistic‑regression odds ratios as a plain‑English benchmark, and **bias‑test recall/precision/calibration across deprivation, ethnicity, sex and age** to catch systematic under‑flagging. The model **prioritises; professionals decide** (human‑in‑the‑loop). To a non‑technical client: *"This is the 200 residents most likely to face a crisis next year, the main reason for each, checked to work fairly across deprived and minority groups — a prioritisation aid, not an automated decision."*
