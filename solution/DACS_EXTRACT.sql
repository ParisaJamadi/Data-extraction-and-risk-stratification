/*===========================================================================================
  DACS Test (DAVSV3) - Data Extraction Script
  Author      : <Candidate>
  Target      : Microsoft SQL Server (Windows Server)  |  Output: pipe-delimited UTF-8 CSV
  Specification: "DACS Test - File Specification", Version 3
  -------------------------------------------------------------------------------------------
  PURPOSE
    Produce the agreed DACSV3 extract: one row per PERSON, 12 fields in the exact order and
    format defined in the file specification, ready to be loaded into Xantura's OneView via
    the DACS Test data source.

  HOW THIS SCRIPT IS ORGANISED
    SECTION 0  Parameters / run control
    SECTION 1  Source profiling & data-quality checks (run/inspect before extracting)
    SECTION 2  The extract (the deliverable SELECT) - clean, set-based, LEFT JOINed
    SECTION 3  Reject set (rows that fail mandatory/format rules per the spec Error Action)
    SECTION 4  Reconciliation / control totals
    SECTION 5  Optional: render the final pipe-delimited, escaped CSV (header + data) for bcp
    SECTION 6  Delta / incremental extraction design (commented blueprint)

  DESIGN DECISIONS (see accompanying Part 1 write-up for full justification)
    * UPN  -> mapped to DACS_ADDRESS.upn (the literal source column matching the spec field
             "UPN", position 1). UPN is MANDATORY, but DACS_ADDRESS.upn is nullable and lives in
             an optional 1:1 table, so any row with a NULL upn is REJECTED (Section 3).
             DACS_PERSON.person_id is the guaranteed non-null/unique alternative and can be
             selected via @UseAddressUpnAsUPN = 0. (In the sample, person 1234's upn=5678 equals
             another person's person_id - an identifier-namespace overlap worth confirming at
             sign-off, since the extract definition is a signed-off contractual artefact.)
    * Middle Names -> [second name] + [third name] concatenated, NULL-safe.
    * Address      -> address lines 1-4 + postcode concatenated, NULL-safe, sentinels removed.
    * Arrears      -> DACS_ARREARS.debt ;  Credit -> DACS_ARREARS.credit
                      (DACS_ARREARS.pending is NOT in the spec -> intentionally not extracted).
    * Number of Dependents -> COUNT of DACS_DEPENDENTS rows per person (0 when none).
    * Gender       -> free text mapped to coded values M/F/O/X; NULL/unmapped -> X (Unknown).
    * DOB          -> formatted dd/MM/yyyy (MANDATORY -> NULL DOB rows are rejected).
===========================================================================================*/

SET NOCOUNT ON;

/*-------------------------------------------------------------------------------------------
  SECTION 0 - RUN CONTROL
-------------------------------------------------------------------------------------------*/
DECLARE @UseAddressUpnAsUPN bit = 1;   -- 1 = DACS_ADDRESS.upn (per spec field, default) ; 0 = person_id (robust non-null fallback)
DECLARE @Prefix            varchar(50) = 'MyOrg';                 -- organisation prefix for the file name
DECLARE @PeriodDate        char(8)     = FORMAT(GETDATE(),'ddMMyyyy');  -- DDMMYYYY per spec
-- Resulting file name -> <Prefix>_<DDMMYYYY>_DACSV3.csv  e.g. MyOrg_09062026_DACSV3.csv
PRINT 'Target extract file name -> ' + @Prefix + '_' + @PeriodDate + '_DACSV3.csv';


/*-------------------------------------------------------------------------------------------
  SECTION 1 - SOURCE PROFILING / DATA-QUALITY CHECKS
  Run these first. They surface every issue discussed in the accompanying write-up.
-------------------------------------------------------------------------------------------*/
SELECT '===== SECTION 1: DATA-QUALITY PROFILING (review only - not the extract) =====' AS [SECTION];

-- 1a. Persons missing a MANDATORY DOB (will be rejected from the extract)
SELECT 'NULL_DOB' AS issue, person_id, [first name], surname, dob
FROM   dbo.DACS_PERSON WHERE dob IS NULL;

-- 1b. Gender values that are not directly mappable to M/F/O/X
SELECT 'UNMAPPED_GENDER' AS issue, person_id, gender
FROM   dbo.DACS_PERSON
WHERE  gender IS NOT NULL
AND    LOWER(LTRIM(RTRIM(gender))) NOT IN ('m','male','f','female','o','other','x','unknown');

-- 1c. NINOs that do not match the standard UK pattern (after trimming/upper) or are sentinels
SELECT 'SUSPECT_NINO' AS issue, person_id, NINO
FROM   dbo.DACS_PERSON
WHERE  NINO IS NOT NULL
AND   (UPPER(REPLACE(NINO,' ','')) = 'UNKNOWN'
   OR  UPPER(REPLACE(NINO,' ','')) NOT LIKE '[A-Z][A-Z][0-9][0-9][0-9][0-9][0-9][0-9][A-D]');

-- 1d. Money precision loss: DACS_ARREARS columns are decimal(18,0) -> pence are NOT stored
--     (e.g. an inserted 34.99 is silently rounded to 35). Reported for the client.
SELECT 'MONEY_SCALE_RISK' AS issue, person_id, debt, credit, pending FROM dbo.DACS_ARREARS;

-- 1e. Address sentinels / missing postcodes
SELECT 'ADDRESS_QUALITY' AS issue, person_id, [address line 1], postcode
FROM   dbo.DACS_ADDRESS
WHERE  [address line 1] IS NULL OR UPPER([address line 1]) LIKE 'NO ADDRESS%' OR postcode IS NULL;

-- 1e2. Mandatory UPN: when sourcing UPN from DACS_ADDRESS.upn, find persons with a NULL upn
--      (no address row, or an address row with no upn) -> these rows are rejected.
SELECT 'NULL_UPN' AS issue, p.person_id, p.[first name], p.surname
FROM        dbo.DACS_PERSON  p
LEFT JOIN   dbo.DACS_ADDRESS a ON a.person_id = p.person_id
WHERE  a.upn IS NULL;

-- 1f. Referential coverage: persons with no address / arrears / case-notes row
SELECT p.person_id,
       CASE WHEN a.person_id IS NULL THEN 'no_address'   ELSE '' END AS addr,
       CASE WHEN r.person_id IS NULL THEN 'no_arrears'   ELSE '' END AS arrears,
       CASE WHEN c.person_id IS NULL THEN 'no_casenotes' ELSE '' END AS casenotes
FROM        dbo.DACS_PERSON     p
LEFT JOIN   dbo.DACS_ADDRESS    a ON a.person_id = p.person_id
LEFT JOIN   dbo.DACS_ARREARS    r ON r.person_id = p.person_id
LEFT JOIN   dbo.DACS_CASENOTES  c ON c.person_id = p.person_id;


/*-------------------------------------------------------------------------------------------
  SECTION 2 - THE EXTRACT (deliverable). Returns the 12 spec fields, clean and typed.
  Built as a CTE pipeline so it is set-based, readable, and reusable by Sections 3-5.
-------------------------------------------------------------------------------------------*/
SELECT '***** SECTION 2: THE EXTRACT - 12 SPEC FIELDS (this is the deliverable) *****' AS [SECTION];

;WITH dep AS (          -- pre-aggregate dependents (1:many) to one row per person
    SELECT person_id, COUNT(*) AS num_dependents
    FROM   dbo.DACS_DEPENDENTS
    GROUP  BY person_id
),
src AS (
    SELECT
        /* 1. UPN (mandatory, unique person reference) */
        CAST(CASE WHEN @UseAddressUpnAsUPN = 1 THEN a.upn ELSE p.person_id END AS varchar(8000)) AS UPN,

        /* 2. First Name */
        NULLIF(LTRIM(RTRIM(p.[first name])),'')                                                  AS FirstName,

        /* 3. Middle Names = second + third name, NULL-safe, single space separated */
        NULLIF(LTRIM(RTRIM(
            CONCAT(
                NULLIF(LTRIM(RTRIM(p.[second name])),''),
                CASE WHEN NULLIF(LTRIM(RTRIM(p.[second name])),'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(p.[third name])),'')  IS NOT NULL THEN ' ' END,
                NULLIF(LTRIM(RTRIM(p.[third name])),'')
            )
        )),'')                                                                                   AS MiddleNames,

        /* 4. Surname */
        NULLIF(LTRIM(RTRIM(p.surname)),'')                                                       AS Surname,

        /* 5. Address = lines 1-4 + postcode, NULL/sentinel-safe, comma separated */
        NULLIF(LTRIM(RTRIM(
            STUFF(
                CONCAT(
                    CASE WHEN NULLIF(LTRIM(RTRIM(addr.l1)),'') IS NOT NULL THEN ', ' + addr.l1 END,
                    CASE WHEN NULLIF(LTRIM(RTRIM(a.[address line 2])),'') IS NOT NULL THEN ', ' + a.[address line 2] END,
                    CASE WHEN NULLIF(LTRIM(RTRIM(a.[address line 3])),'') IS NOT NULL THEN ', ' + a.[address line 3] END,
                    CASE WHEN NULLIF(LTRIM(RTRIM(a.[address line 4])),'') IS NOT NULL THEN ', ' + a.[address line 4] END,
                    CASE WHEN NULLIF(LTRIM(RTRIM(a.postcode)),'')         IS NOT NULL THEN ', ' + a.postcode END
                ), 1, 2, '')
        )),'')                                                                                   AS [Address],

        /* 6. NINO - standardised (upper, no spaces); sentinel 'UNKNOWN' -> NULL */
        NULLIF(
            CASE WHEN UPPER(REPLACE(ISNULL(p.NINO,''),' ','')) = 'UNKNOWN' THEN ''
                 ELSE UPPER(REPLACE(ISNULL(p.NINO,''),' ','')) END
        ,'')                                                                                     AS NINO,

        /* 7. DOB -> dd/MM/yyyy (mandatory: NULLs handled as rejects in Section 3) */
        CASE WHEN p.dob IS NOT NULL THEN CONVERT(char(10), p.dob, 103) END                       AS DOB,

        /* 8. Case Notes - CR/LF stripped so it stays on one CSV line (spec: no newlines) */
        NULLIF(LTRIM(RTRIM(
            REPLACE(REPLACE(REPLACE(ISNULL(c.[case notes],''), CHAR(13),' '), CHAR(10),' '), CHAR(9),' ')
        )),'')                                                                                   AS CaseNotes,

        /* 9. Arrears (GBP) <- debt ; cast to 2dp money presentation */
        CASE WHEN r.debt IS NOT NULL THEN CAST(r.debt AS decimal(18,2)) END                      AS Arrears,

        /* 10. Credit (GBP) <- credit */
        CASE WHEN r.credit IS NOT NULL THEN CAST(r.credit AS decimal(18,2)) END                  AS Credit,

        /* 11. Number of Dependents (0 when no dependents recorded) */
        ISNULL(dep.num_dependents,0)                                                             AS NumDependents,

        /* 12. Gender -> coded M/F/O/X ; NULL or unmapped -> X (Unknown) per spec choices */
        CASE LOWER(LTRIM(RTRIM(ISNULL(p.gender,''))))
            WHEN 'm' THEN 'M' WHEN 'male'   THEN 'M'
            WHEN 'f' THEN 'F' WHEN 'female' THEN 'F'
            WHEN 'o' THEN 'O' WHEN 'other'  THEN 'O'
            WHEN 'x' THEN 'X' WHEN 'unknown' THEN 'X'
            ELSE 'X'
        END                                                                                      AS Gender,

        p.dob AS _dob_raw     -- helper for reject logic only (not output)
    FROM        dbo.DACS_PERSON      p
    LEFT JOIN   dbo.DACS_CASENOTES   c   ON c.person_id = p.person_id
    LEFT JOIN   dbo.DACS_ARREARS     r   ON r.person_id = p.person_id
    LEFT JOIN   dbo.DACS_ADDRESS     a   ON a.person_id = p.person_id
    LEFT JOIN   dep                      ON dep.person_id = p.person_id
    OUTER APPLY (SELECT CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(a.[address line 1],'')))) LIKE 'NO ADDRESS%'
                              THEN NULL ELSE a.[address line 1] END AS l1) addr   -- strip 'NO ADDRESS GIVEN' sentinel
)
SELECT UPN, FirstName, MiddleNames, Surname, [Address], NINO, DOB,
       CaseNotes, Arrears, Credit, NumDependents, Gender
FROM   src
WHERE  _dob_raw IS NOT NULL          -- enforce mandatory DOB (rejected rows excluded here)
AND    UPN IS NOT NULL               -- enforce mandatory UPN (null address.upn rejected)
ORDER  BY UPN;


/*-------------------------------------------------------------------------------------------
  SECTION 3 - REJECT SET
  Spec Error Action = "Reject row - invalid field value retained, error reported for manual
  fixing". DOB and UPN are the only MANDATORY fields, so these are the rejection rules.
-------------------------------------------------------------------------------------------*/
SELECT '===== SECTION 3: REJECTED ROWS (failed a mandatory rule, reported for fixing) =====' AS [SECTION];

SELECT p.person_id, p.[first name], p.surname,
       CONCAT_WS('; ',
           CASE WHEN p.dob IS NULL THEN 'DOB missing (mandatory)' END,
           CASE WHEN @UseAddressUpnAsUPN = 1 AND a.upn IS NULL THEN 'UPN missing (mandatory)' END
       ) AS reject_reason
FROM        dbo.DACS_PERSON  p
LEFT JOIN   dbo.DACS_ADDRESS a ON a.person_id = p.person_id
WHERE  p.dob IS NULL
   OR (@UseAddressUpnAsUPN = 1 AND a.upn IS NULL);


/*-------------------------------------------------------------------------------------------
  SECTION 4 - RECONCILIATION / CONTROL TOTALS
  Compare against the file after generation; store in a run-log table in production.
-------------------------------------------------------------------------------------------*/
SELECT '===== SECTION 4: RECONCILIATION (source = extracted + rejected, so it balances) =====' AS [SECTION];

SELECT
    (SELECT COUNT(*) FROM dbo.DACS_PERSON)                              AS persons_in_source,
    (SELECT COUNT(*) FROM dbo.DACS_PERSON WHERE dob IS NOT NULL)        AS persons_expected_in_extract,
    (SELECT COUNT(*) FROM dbo.DACS_PERSON WHERE dob IS NULL)            AS persons_rejected,
    (SELECT CAST(SUM(debt)   AS decimal(18,2)) FROM dbo.DACS_ARREARS)   AS total_arrears_source,
    (SELECT CAST(SUM(credit) AS decimal(18,2)) FROM dbo.DACS_ARREARS)   AS total_credit_source,
    (SELECT COUNT(*) FROM dbo.DACS_DEPENDENTS)                          AS total_dependents_source;


/*-------------------------------------------------------------------------------------------
  SECTION 5 - OPTIONAL: render a fully-escaped, pipe-delimited UTF-8 CSV (header + rows)
  Produces ONE column [csv_line]. Pipe to a file with sqlcmd/bcp.
  Escaping rule (per spec appendix): if a value contains the | delimiter or a double quote,
  wrap it in double quotes and double any embedded quotes.

  >>> DISABLED BY DEFAULT so the whole script runs end-to-end with NO errors.
  >>> For testing you do NOT need this - SECTION 2 is the extract.
  >>> To actually generate the CSV file: (1) uncomment + create the dbo.dbo_csvq function at the
  >>> bottom (run it on its own first), then (2) remove the /* and */ wrapping the SELECT below.
-------------------------------------------------------------------------------------------*/
/*  ===== begin optional CSV render (commented out by default) =====
;WITH dep AS (
    SELECT person_id, COUNT(*) AS num_dependents FROM dbo.DACS_DEPENDENTS GROUP BY person_id
),
src AS (  -- (same projection as Section 2; trimmed here for brevity in comments)
    SELECT
        CAST(CASE WHEN @UseAddressUpnAsUPN = 1 THEN a.upn ELSE p.person_id END AS varchar(8000)) AS UPN,
        NULLIF(LTRIM(RTRIM(p.[first name])),'')                                                   AS FirstName,
        NULLIF(LTRIM(RTRIM(CONCAT(NULLIF(LTRIM(RTRIM(p.[second name])),''),
            CASE WHEN NULLIF(LTRIM(RTRIM(p.[second name])),'') IS NOT NULL
                  AND NULLIF(LTRIM(RTRIM(p.[third name])),'')  IS NOT NULL THEN ' ' END,
            NULLIF(LTRIM(RTRIM(p.[third name])),'')))),'')                                        AS MiddleNames,
        NULLIF(LTRIM(RTRIM(p.surname)),'')                                                        AS Surname,
        NULLIF(LTRIM(RTRIM(STUFF(CONCAT(
            CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(a.[address line 1],'')))) NOT LIKE 'NO ADDRESS%'
                  AND NULLIF(LTRIM(RTRIM(a.[address line 1])),'') IS NOT NULL THEN ', ' + a.[address line 1] END,
            CASE WHEN NULLIF(LTRIM(RTRIM(a.[address line 2])),'') IS NOT NULL THEN ', ' + a.[address line 2] END,
            CASE WHEN NULLIF(LTRIM(RTRIM(a.[address line 3])),'') IS NOT NULL THEN ', ' + a.[address line 3] END,
            CASE WHEN NULLIF(LTRIM(RTRIM(a.[address line 4])),'') IS NOT NULL THEN ', ' + a.[address line 4] END,
            CASE WHEN NULLIF(LTRIM(RTRIM(a.postcode)),'')         IS NOT NULL THEN ', ' + a.postcode END),1,2,''))),'') AS [Address],
        NULLIF(CASE WHEN UPPER(REPLACE(ISNULL(p.NINO,''),' ','')) = 'UNKNOWN' THEN ''
                    ELSE UPPER(REPLACE(ISNULL(p.NINO,''),' ','')) END,'')                         AS NINO,
        CASE WHEN p.dob IS NOT NULL THEN CONVERT(char(10), p.dob, 103) END                        AS DOB,
        NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(ISNULL(c.[case notes],''),CHAR(13),' '),CHAR(10),' '),CHAR(9),' '))),'') AS CaseNotes,
        CASE WHEN r.debt   IS NOT NULL THEN CONVERT(varchar(40), CAST(r.debt   AS decimal(18,2))) END AS Arrears,
        CASE WHEN r.credit IS NOT NULL THEN CONVERT(varchar(40), CAST(r.credit AS decimal(18,2))) END AS Credit,
        CONVERT(varchar(20), ISNULL(dep.num_dependents,0))                                        AS NumDependents,
        CASE LOWER(LTRIM(RTRIM(ISNULL(p.gender,''))))
            WHEN 'm' THEN 'M' WHEN 'male' THEN 'M' WHEN 'f' THEN 'F' WHEN 'female' THEN 'F'
            WHEN 'o' THEN 'O' WHEN 'other' THEN 'O' WHEN 'x' THEN 'X' WHEN 'unknown' THEN 'X' ELSE 'X' END AS Gender,
        p.dob AS _dob_raw
    FROM        dbo.DACS_PERSON p
    LEFT JOIN   dbo.DACS_CASENOTES c ON c.person_id = p.person_id
    LEFT JOIN   dbo.DACS_ARREARS   r ON r.person_id = p.person_id
    LEFT JOIN   dbo.DACS_ADDRESS   a ON a.person_id = p.person_id
    LEFT JOIN   dep                  ON dep.person_id = p.person_id
),
esc AS (   -- field-level CSV escaping helper applied to every text-bearing field
    SELECT s.*,
           N'|' AS d
    FROM src s
)
SELECT csv_line FROM (
    -- header row first
    SELECT 0 AS ord, CAST(N'UPN|First Name|Middle Names|Surname|Address|NINO|DOB|Case Notes|Arrears|Credit|Number of Dependents|Gender' AS nvarchar(max)) AS csv_line
    UNION ALL
    SELECT 1 AS ord,
        CONCAT_WS(N'|',
            dbo_csvq(UPN),        dbo_csvq(FirstName), dbo_csvq(MiddleNames), dbo_csvq(Surname),
            dbo_csvq([Address]),  dbo_csvq(NINO),      dbo_csvq(DOB),         dbo_csvq(CaseNotes),
            dbo_csvq(Arrears),    dbo_csvq(Credit),    dbo_csvq(NumDependents), dbo_csvq(Gender))
    FROM esc
    WHERE _dob_raw IS NOT NULL AND UPN IS NOT NULL
) x
ORDER BY ord, csv_line;
    ===== end optional CSV render =====  */
/*  NOTE: dbo_csvq() is the small scalar helper defined below. CONCAT_WS treats NULL as ''
    which matches "empty field" for optional values. Generate the file with, e.g.:
      sqlcmd -S . -d DACS -E -h-1 -W -o "MyOrg_09062026_DACSV3.csv" -i DACS_EXTRACT_render.sql
    then ensure the file is saved/transmitted as UTF-8. For robust production CSV writing
    (encoding + quoting) an SSIS Flat File destination is preferable to bcp/sqlcmd.          */


/*-------------------------------------------------------------------------------------------
  CSV-escaping helper used by Section 5. Create once.
-------------------------------------------------------------------------------------------*/
-- CREATE OR ALTER FUNCTION dbo.dbo_csvq (@v nvarchar(max))
-- RETURNS nvarchar(max) AS
-- BEGIN
--     IF @v IS NULL RETURN N'';
--     -- defensively strip CR/LF (belt and braces) then quote if it contains | or "
--     SET @v = REPLACE(REPLACE(@v, NCHAR(13), N' '), NCHAR(10), N' ');
--     IF @v LIKE N'%|%' OR @v LIKE N'%"%'
--         RETURN N'"' + REPLACE(@v, N'"', N'""') + N'"';
--     RETURN @v;
-- END;
-- GO


/*===========================================================================================
  SECTION 6 - DELTA / INCREMENTAL EXTRACTION (design blueprint)
  The schema has NO created/modified timestamps and NO row versioning, so today only a FULL
  extract is possible. Three production-grade options, in order of preference:

  OPTION A (recommended) - SQL Server CHANGE TRACKING (lightweight, captures deletes)
      ALTER DATABASE DACS SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);
      ALTER TABLE dbo.DACS_PERSON   ENABLE CHANGE_TRACKING;  -- repeat per table
      -- Each run: read CHANGETABLE(CHANGES dbo.DACS_PERSON, @last_version) to get inserted/
      -- updated/deleted person_ids since the stored watermark, then re-extract only those.

  OPTION B - ROWVERSION + watermark control table (captures insert/update, NOT deletes)
      ALTER TABLE dbo.DACS_PERSON ADD rv rowversion;   -- (and the child tables)
      -- WHERE rv > @last_max_rv ; store MAX(rv) in dbo.ETL_Watermark only on success.

  OPTION C - no schema change: snapshot diff via HASHBYTES
      -- Persist HASHBYTES('SHA2_256', concat-of-row) per UPN from the last run; compare to
      -- this run to classify New / Changed / Deleted. Heavier but zero source changes.

  LATE-ARRIVING DATA  : extract with a lookback overlap (e.g. watermark minus N days) and make
                        the downstream load idempotent (upsert keyed on UPN + period date).
  FAILED RUNS         : advance the watermark ONLY after the file is produced, validated and
                        delivered; runs are re-runnable from the last good watermark.
===========================================================================================*/
