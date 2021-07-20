[CmdletBinding()]
param
(
	[Parameter(Mandatory = $true)]
    [System.String]
    $MachineName,

    [Parameter(Mandatory = $true)]
    [System.String]
    $InstanceName,

	[Parameter()]
    [System.String]
    $AvailabilityGroupName,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $FullBackupFrequency,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $DiffBackupFrequency,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $TlogBackupFrequency,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $MissedFullBackupsWarningThreshold,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $MissedDiffBackupsWarningThreshold,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $MissedTlogBackupsWarningThreshold,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $MissedFullBackupsCriticalThreshold,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $MissedDiffBackupsCriticalThreshold,

    [Parameter(Mandatory = $true)]
    [System.Int32]
    $MissedTlogBackupsCriticalThreshold,

    [Parameter()]
    [System.String]
    $ExcludeFromAllBackups,
    
    [Parameter()]
    [System.String]
    $ExcludeFromFullBackup,

    [Parameter()]
    [System.String]
    $ExcludeFromDiffBackup,

    [Parameter()]
    [System.String]
    $ExcludeFromTlogBackup,

    [Parameter(Mandatory = $true)]
    [System.String]
    $IgnoreBackupStatusForReadableSecondaries,

    [Parameter()]
    [Switch]
    $ConsoleTask,

	[Parameter()]
	[System.String]
	$DebugLogging = 'false',

    [Parameter()]
    [Switch]
    $TestRun
)

#region initialize script

$debug = [System.Boolean]::Parse($DebugLogging)
$parameterString = $PSBoundParameters.GetEnumerator() | ForEach-Object -Process { "`n$($_.Key) => $($_.Value)" }

# Enable Write-Debug without inquiry when debug is enabled
if ($debug -or $DebugPreference -ne 'SilentlyContinue')
{
    $DebugPreference = 'Continue'
}

# Import the helper functions
if ( -not $TestRun )
{
    . '$FileResource[Name="SqlServerSupplemental.HelperFunctions"]/Path$'
}
else
{
    $helperFunctionsPath = Join-Path -Path $PSScriptRoot -ChildPath HelperFunctions.ps1
    . $helperFunctionsPath
}

$scriptName = 'Get-DatabaseBackupStatus.ps1'
$scriptEventID = 19531 # randomly generated for this script

# Gather the start time of the script
$startTime = Get-Date

# If TestRun is specified, skip loading MOM API
if (-not $TestRun)
{
    # Load MOMScript API
    $momapi = New-Object -comObject MOM.ScriptAPI
}

trap
{
	$message = "`n $parameterString `n $($_.ToString())"

    if (-not $TestRun)
    {
        $momapi.LogScriptEvent($scriptName, $scriptEventID, 1, $message)
    }

    Write-Debug -Message $message

    break
}

# Log script event that we are starting task
if ($debug)
{
    $message = "`nScript is starting. $parameterString"

    if (-not $TestRun)
    {
        $momapi.LogScriptEvent($scriptName, $scriptEventID, 0, $message)
    }

    Write-Debug -Message $message
}

#endregion initialize script

#region functions
function FormatalertDetails
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Text.StringBuilder]
        $alertDetails,

        [Parameter()]
        [System.Object[]]
        $BackupDetails,

        [Parameter(Mandatory = $true)]
        [System.Int32]
        $Threshold,

        [Parameter(Mandatory = $true)]
        [System.String]
        $CountProperty
    )

    $backupTypes = @{
        full = 'full'
        diff = 'differential'
        tlog = 'transaction log'
    }

    if ( $BackupDetails.Count -gt 0 )
    {
        if ( $CountProperty -match '^missed_(\w+)_backups$' )
        {
            $backupTypeCode = $matches[1]
        }

        $backupType = $backupTypes[$backupTypeCode]

        $alertDetails.AppendLine("  Databases missing $Threshold or more $backupType backups:") > $null

        foreach ( $database in ( $BackupDetails | Sort-Object -Property database_name ) )
        {
            $alertDetails.AppendLine("    - $($database.database_name): $($database.$CountProperty)") > $null
        }
    }

    $alertDetails.AppendLine('') > $null
    return $alertDetails
}
#endregion functions

#region constants

$ignoreReadableSecondaryStatus = [System.Boolean]::Parse($IgnoreBackupStatusForReadableSecondaries)

# Create a health state enum
enum HealthState {
    Healthy;
    Warning;
    Critical
}

$query = @'
DECLARE @ReportDate datetime2 = GETDATE()

;WITH [BackupCTE] AS
(
    SELECT
        [MostRecentBackup].[database_name],
		[MostRecentBackup].[availability_group_name],
        [MostRecentBackup].[secondary_role_allow_connections],
        [MostRecentBackup].[recovery_model],
        [MostRecentBackup].[create_date],
        [MostRecentBackup].[D] AS [last_full_backup],
        [MostRecentBackup].[I] AS [last_diff_backup],
        [MostRecentBackup].[L] AS [last_tlog_backup]
    FROM
    (
        SELECT
            [d].[name] AS [database_name],
			[ag].[name] AS [availability_group_name],
            [ar].[secondary_role_allow_connections_desc] AS [secondary_role_allow_connections],
            [d].[recovery_model_desc] AS [recovery_model],
            [d].[create_date],
            [b].[type],
            [b].[backup_finish_date]
        FROM [sys].[databases] AS [d]
        LEFT OUTER JOIN [dbo].[backupset] AS [b] ON
            [b].[database_name] = [d].[name]
		LEFT OUTER JOIN [sys].[availability_databases_cluster] AS [adc] ON
			[d].[name] = [adc].[database_name]
		LEFT OUTER JOIN [sys].[availability_groups] AS [ag] ON
			[adc].[group_id] = [ag].[group_id]
        LEFT OUTER JOIN [sys].[availability_replicas] AS [ar] ON
            [ag].[group_id] = [ar].[group_id] AND @@SERVERNAME = [ar].[replica_server_name]
        LEFT OUTER JOIN [sys].[dm_hadr_availability_replica_states] AS [ars] ON
            [ar].[replica_id] = [ars].[replica_id] AND [ag].[group_id] = [ars].[group_id]
        WHERE
            [d].[state] = 0
            AND
            (
                [ars].[role] IS NULL
                OR [ars].[role] = 1
                OR
                (
                    [ar].[secondary_role_allow_connections] <> 0
                    AND [ars].[role] <> 1
                )
            )
    ) AS [SourceTable]
    PIVOT
    (
        MAX([SourceTable].[backup_finish_date]) FOR [SourceTable].[type] IN (D, I, L)
    ) AS [MostRecentBackup]
)

SELECT
    [b].[database_name],
	[b].[availability_group_name],
    [b].[secondary_role_allow_connections],
    [b].[recovery_model],
    COALESCE([b].[last_full_backup],[b].[create_date]) AS [last_full_backup],
    FLOOR(DATEDIFF(MINUTE, COALESCE([b].[last_full_backup],[b].[create_date]), @ReportDate) / @FullBackupFrequency) AS [missed_full_backups],
    COALESCE([b].[last_diff_backup],[b].[create_date]) AS [last_diff_backup],
    FLOOR(DATEDIFF(MINUTE, COALESCE([b].[last_diff_backup],[b].[create_date]), @ReportDate) / @DiffBackupFrequency) AS [missed_diff_backups],
    COALESCE([b].[last_tlog_backup],[b].[create_date]) AS [last_tlog_backup],
    CASE
        WHEN [b].[recovery_model] = 'SIMPLE' THEN 0
        ELSE FLOOR(DATEDIFF(MINUTE, COALESCE([b].[last_tlog_backup],[b].[create_date]), @ReportDate) / @TlogBackupFrequency)
    END AS [missed_tlog_backups]
FROM [BackupCTE] AS [b]
'@

#endregion constants

#region Script Body

# Assume the backups are healthy to start
$healthState = [HealthState]::Healthy.ToString()

try
{
    # Connect to the instance right away
    $sqlConnection = Connect-SQL -ServerName $MachineName -InstanceName $InstanceName -ErrorAction Stop
}
catch
{
    $message = "`n Connect-SQL `n $($_.ToString())"

    if (-not $TestRun)
    {
	    $momapi.LogScriptEvent($scriptName, $scriptEventID, 1, $message)
    }
	
    Write-Debug -Message $message
    exit
}

$queryParameters = @{
    FullBackupFrequency = $FullBackupFrequency
    DiffBackupFrequency = $DiffBackupFrequency
    TlogBackupFrequency = $TlogBackupFrequency
}

try
{
	Write-Verbose -Message "Executing query to get the backup status of all databases"
	$invokeSqlQueryParameters = @{
		Connection = $sqlConnection
		DatabaseName = 'msdb'
        QueryParameters = $queryParameters
		QueryString = $query
		WithResults = $true
	}
	$queryResult = Invoke-SqlQuery @invokeSqlQueryParameters
}
catch
{
	$message = "`n Database: $dbName `n Invoke-SqlQuery `n $($_.ToString())"

    if (-not $TestRun)
    {
	    $momapi.LogScriptEvent($scriptName, $scriptEventID, 1, $message)
    }
	
    Write-Debug -Message $message
    exit
}

if ( [System.String]::IsNullOrEmpty($AvailabilityGroupName) )
{
    $queryResult = $queryResult | Where-Object -FilterScript { [System.String]::IsNullOrEmpty($_.availability_group_name) }

    $databasesString = ( $queryResult | Sort-Object -Property database_name | Select-Object -ExpandProperty database_name ) -join "`n  - "
    $message = "`nProcessing databases not in an availability group:`n  - $databasesString"

    if (-not $TestRun)
    {
        $momapi.LogScriptEvent($scriptName, $scriptEventID, 0, $message)
    }

    Write-Debug -Message $message
}
else
{
    $queryResult = $queryResult | Where-Object -Property availability_group_name -EQ $AvailabilityGroupName

    $databasesString = ( $queryResult | Sort-Object -Property database_name | Select-Object -ExpandProperty database_name ) -join "`n  - "
    $message = "`nProcessing databases in the availability group '$AvailabilityGroupName':`n  - $databasesString"

    if (-not $TestRun)
    {
        $momapi.LogScriptEvent($scriptName, $scriptEventID, 0, $message)
    }

    Write-Debug -Message $message
}

# Process the AG secondaries
$queryResult = $queryResult 
if ( $ignoreReadableSecondaryStatus )
{
    
}

# Process the exclusions from all backups
if ( -not [System.String]::IsNullOrEmpty($ExcludeFromAllBackups) )
{
    if ($debug)
    {
        $databasesToExclude = ( $queryResult | Where-Object -Property database_name -Match $ExcludeFromAllBackups | Select-Object -ExpandProperty database_name ) -join "`n  - "
        $message = "`nExcluding the following databases from all backup checks:`n  - $databasesToExclude"

        if (-not $TestRun)
        {
            $momapi.LogScriptEvent($scriptName, $scriptEventID, 0, $message)
        }

        Write-Debug -Message $message
    }
    $queryResult = $queryResult | Where-Object -Property database_name -NotMatch $ExcludeFromAllBackups
}

#region Process the full backups

if ( -not [System.String]::IsNullOrEmpty($ExcludeFromFullBackup) )
{
    $fullBackupsToProcess = $queryResult | Where-Object -Property database_name -NotMatch $ExcludeFromFullBackup
}
else
{
    $fullBackupsToProcess = $queryResult
}

$fullBackupsWarning = $fullBackupsToProcess |
    Where-Object -Property missed_full_backups -GE $MissedFullBackupsWarningThreshold |
    Where-Object -Property missed_full_backups -LT $MissedFullBackupsCriticalThreshold

$fullBackupsCritical = $fullBackupsToProcess |
    Where-Object -Property missed_full_backups -GE $MissedFullBackupsCriticalThreshold

#endregion Process the full backups

#region Process the differential backups

if ( -not [System.String]::IsNullOrEmpty($ExcludeFromDiffBackup) )
{
    $diffBackupsToProcess = $queryResult | Where-Object -Property database_name -NotMatch $ExcludeFromDiffBackup
}
else
{
    $diffBackupsToProcess = $queryResult
}

$diffBackupsWarning = $diffBackupsToProcess |
    Where-Object -Property missed_diff_backups -GE $MissedDiffBackupsWarningThreshold |
    Where-Object -Property missed_diff_backups -LT $MissedDiffBackupsCriticalThreshold

$diffBackupsCritical = $diffBackupsToProcess |
    Where-Object -Property missed_diff_backups -GE $MissedDiffBackupsCriticalThreshold

#endregion Process the differential backups

#region Process the transaction log backups

if ( -not [System.String]::IsNullOrEmpty($ExcludeFromTlogBackup) )
{
    $tlogBackupsToProcess = $queryResult | Where-Object -Property database_name -NotMatch $ExcludeFromTlogBackup
}
else
{
    $tlogBackupsToProcess = $queryResult
}

$tlogBackupsWarning = $tlogBackupsToProcess |
    Where-Object -Property missed_tlog_backups -GE $MissedTlogBackupsWarningThreshold |
    Where-Object -Property missed_tlog_backups -LT $MissedTlogBackupsCriticalThreshold

$tlogBackupsCritical = $tlogBackupsToProcess |
    Where-Object -Property missed_tlog_backups -GE $MissedTlogBackupsCriticalThreshold

#endregion Process the transaction log backups

#region determine health

$warningCount = $fullBackupsWarning.Count + $diffBackupsWarning.Count + $tlogBackupsWarning.Count
if ( $warningCount -gt 0 )
{
    $healthState = [HealthState]::Warning.ToString()
}

$criticalCount = $fullBackupsCritical.Count + $diffBackupsCritical.Count + $tlogBackupsCritical.Count
if ( $criticalCount -gt 0 )
{
    $healthState = [HealthState]::Critical.ToString()
}

#endregion determine health

#region format alert details text

$alertDetails = [System.Text.StringBuilder]::new()

if ( $criticalCount -gt 0 )
{
    $alertDetails.AppendLine('Critical alerts:') > $null
    $alertDetails = FormatalertDetails -alertDetails $alertDetails -BackupDetails $fullBackupsCritical -Threshold $MissedFullBackupsCriticalThreshold -CountProperty missed_full_backups
    $alertDetails = FormatalertDetails -alertDetails $alertDetails -BackupDetails $diffBackupsCritical -Threshold $MissedDiffBackupsCriticalThreshold -CountProperty missed_diff_backups
    $alertDetails = FormatalertDetails -alertDetails $alertDetails -BackupDetails $tlogBackupsCritical -Threshold $MissedTlogBackupsCriticalThreshold -CountProperty missed_tlog_backups
}

if ( $warningCount -gt 0 )
{
    $alertDetails.AppendLine('Warning alerts:') > $null
    $alertDetails = FormatalertDetails -alertDetails $alertDetails -BackupDetails $fullBackupsWarning -Threshold $MissedFullBackupsWarningThreshold -CountProperty missed_full_backups
    $alertDetails = FormatalertDetails -alertDetails $alertDetails -BackupDetails $diffBackupsWarning -Threshold $MissedDiffBackupsWarningThreshold -CountProperty missed_diff_backups
    $alertDetails = FormatalertDetails -alertDetails $alertDetails -BackupDetails $tlogBackupsWarning -Threshold $MissedTlogBackupsWarningThreshold -CountProperty missed_tlog_backups
}

$alertDetailsString = $alertDetails.ToString()

#endregion format alert details text

#region return results

if ( $debug )
{
	$bagsString = "`nHealth State: $healthState`nDetails:`n$alertDetailsString"
	$message = "`nProperty bag values: $bagsString"
    
    if (-not $TestRun)
    {
	    $momapi.LogScriptEvent($scriptName, $scriptEventID, 0, $message)
    }

	Write-Debug -Message $message
}

if (-not $TestRun -and -not $ConsoleTask)
{
    $bag = $momapi.CreatePropertyBag()
    $bag.AddValue('Health',$healthState)
    $bag.AddValue('Details',$alertDetailsString)

    # Return the property bag
	#$momapi.Return($bag)
	$bag
}

if ($ConsoleTask)
{
    return $alertDetailsString
}

#endregion return results

#endregion Script Body

# Log an event for script ending and total execution time.
$endTime = Get-Date
$scriptTime = ($endTime - $startTime).TotalSeconds

if ($debug)
{
    $message = "`n Script Completed. `n Script Runtime: ($scriptTime) seconds."

    if (-not $TestRun)
    {
        $momapi.LogScriptEvent($scriptName, $scriptEventID, 0, $message)
    }

    Write-Debug -Message $message
}
