/*===========================================================================================
  DACS_EXPORT_CSV.sql
  Purpose : Produce the FINAL spec-compliant output as a single column [csv_line] -
            pipe-delimited (|), header row first, with proper double-quote escaping and
            newlines stripped, ready to be written to a .csv file via sqlcmd.

  This is a self-contained version of Section 5 of DACS_EXTRACT.sql:
    1) creates the small escaping helper function dbo.dbo_csvq
    2) selects one line per row (header + data) into a single column

  HOW TO TURN THIS INTO A .csv FILE (run from PowerShell in the repo root, one line):
    sqlcmd -S localhost\SQLEXPRESS -d DACS -E -C -h -1 -W -f 65001 ^
      -i ".\solution\DACS_EXPORT_CSV.sql" ^
      -o ".\solution\MyOrg_09062026_DACSV3.csv"

  Flag meanings: -E Windows login | -C trust local certificate | -h -1 no column header
                 -W trim trailing spaces | -f 65001 UTF-8 | -i input script | -o output file
  (The final value below is CONVERTed to varchar(8000) so -W can trim padding correctly.)
===========================================================================================*/

SET NOCOUNT ON;
GO

CREATE OR ALTER FUNCTION dbo.dbo_csvq (@v nvarchar(max))
RETURNS nvarchar(max) AS
BEGIN
    IF @v IS NULL RETURN N'';
    SET @v = REPLACE(REPLACE(@v, NCHAR(13), N' '), NCHAR(10), N' ');   -- strip CR/LF
    IF @v LIKE N'%|%' OR @v LIKE N'%"%'                                -- quote if it holds | or "
        RETURN N'"' + REPLACE(@v, N'"', N'""') + N'"';
    RETURN @v;
END;
GO

DECLARE @UseAddressUpnAsUPN bit = 1;   -- 1 = DACS_ADDRESS.upn (per spec) ; 0 = person_id fallback

;WITH dep AS (
    SELECT person_id, COUNT(*) AS num_dependents FROM dbo.DACS_DEPENDENTS GROUP BY person_id
),
src AS (
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
)
SELECT CONVERT(varchar(8000), csv_line) AS csv_line FROM (
    SELECT 0 AS ord,
        CAST(N'UPN|First Name|Middle Names|Surname|Address|NINO|DOB|Case Notes|Arrears|Credit|Number of Dependents|Gender' AS nvarchar(max)) AS csv_line
    UNION ALL
    SELECT 1 AS ord,
        CONCAT_WS(N'|',
            dbo.dbo_csvq(UPN),       dbo.dbo_csvq(FirstName),     dbo.dbo_csvq(MiddleNames),
            dbo.dbo_csvq(Surname),   dbo.dbo_csvq([Address]),     dbo.dbo_csvq(NINO),
            dbo.dbo_csvq(DOB),       dbo.dbo_csvq(CaseNotes),     dbo.dbo_csvq(Arrears),
            dbo.dbo_csvq(Credit),    dbo.dbo_csvq(NumDependents), dbo.dbo_csvq(Gender))
    FROM src
    WHERE _dob_raw IS NOT NULL AND UPN IS NOT NULL
) x
ORDER BY ord, csv_line;
GO
