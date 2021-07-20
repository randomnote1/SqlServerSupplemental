### This script does not currently work as a task because the OperationsManager module does not exist on the targeted server
[CmdletBinding()]
param
(
	[Parameter(Mandatory = $true)]
    [System.String]
    $ObjectInstanceID,

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

$scriptName = 'Get-DatabaseBackupStatusTask.ps1'
$scriptEventID = 19532 # randomly generated for this script

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

if ($debug)
{
    $loadedAssemblies = ( [System.AppDomain]::CurrentDomain.GetAssemblies() | Select-Object -ExpandProperty Location -ErrorAction SilentlyContinue | Sort-Object ) -join "`n"
    $message = "`nLoaded Assemblies: $loadedAssemblies"

    if (-not $TestRun)
    {
        $momapi.LogScriptEvent($scriptName, $scriptEventID, 0, $message)
    }

    Write-Debug -Message $message
}

$object = Get-SCOMClassInstance -Id $ObjectInstanceID
$getDatabaseBackupStatusParams = @{
    MachineName = $object.'[Microsoft.SQLServer.Core.DBEngine].MachineName'.Value
    InstanceName = $object.'[Microsoft.SQLServer.Core.DBEngine].InstanceName'.Value
}

$objectProperties = $object | Get-Member -MemberType NoteProperty
if ( $objectProperties.Name -match '\[Microsoft\.SQLServer.Core\.AvailabilityGroupHealth\]\.AvailabilityGroupName' )
{
    $monitor = Get-SCOMMonitor -Name SqlServerSupplemental.BackupStatus.AvailabilityGroup.Monitor
    $getDatabaseBackupStatusParams.AvailabilityGroupName = $object.'[Microsoft.SQLServer.Core.AvailabilityGroupHealth].AvailabilityGroupName'.Value
}
else
{
    $monitor = Get-SCOMMonitor -Name SqlServerSupplemental.BackupStatus.DBEngine.Monitor
}

# Get the default parameters for the monitor
$configuration = [System.Xml.XmlDocument] "<config>$($monitor.Configuration)</config>"
$getDatabaseBackupStatusParams.FullBackupFrequency = $configuration.FullBackupFrequency
$getDatabaseBackupStatusParams.DiffBackupFrequency = $configuration.DiffBackupFrequency
$getDatabaseBackupStatusParams.TlogBackupFrequency = $configuration.TlogBackupFrequency
$getDatabaseBackupStatusParams.MissedFullBackupsWarningThreshold = $configuration.MissedFullBackupsWarningThreshold
$getDatabaseBackupStatusParams.MissedDiffBackupsWarningThreshold = $configuration.MissedDiffBackupsWarningThreshold
$getDatabaseBackupStatusParams.MissedTlogBackupsWarningThreshold = $configuration.MissedTlogBackupsWarningThreshold
$getDatabaseBackupStatusParams.MissedFullBackupsCriticalThreshold = $configuration.MissedFullBackupsCriticalThreshold
$getDatabaseBackupStatusParams.MissedDiffBackupsCriticalThreshold = $configuration.MissedDiffBackupsCriticalThreshold
$getDatabaseBackupStatusParams.MissedTlogBackupsCriticalThreshold = $configuration.MissedTlogBackupsCriticalThreshold
$getDatabaseBackupStatusParams.ExcludeFromAllBackups = $configuration.ExcludeFromAllBackups
$getDatabaseBackupStatusParams.ExcludeFromFullBackup = $configuration.ExcludeFromFullBackup
$getDatabaseBackupStatusParams.ExcludeFromDiffBackup = $configuration.ExcludeFromDiffBackup
$getDatabaseBackupStatusParams.ExcludeFromTlogBackup = $configuration.ExcludeFromTlogBackup
$getDatabaseBackupStatusParams.IgnoreBackupStatusForReadableSecondaries = $configuration.IgnoreBackupStatusForReadableSecondaries
$getDatabaseBackupStatusParams.ConsoleTask = $true
$getDatabaseBackupStatusParams.DebugLogging = $DebugLogging
$getDatabaseBackupStatusParams.TestRun = $TestRun.IsPresent

# Get the monitor-level overrides
$monitorOverrides = Get-SCOMOverride -Monitor $monitor
foreach ( $monitorOverride in $monitorOverrides )
{
    $getDatabaseBackupStatusParams.($monitorOverride.Parameter) = $monitorOverride.Value
}

# Get the object-level overrides
$objectOverrides = Get-SCOMOverride -Monitor $monitor -Instance $object
foreach ( $objectOverride in $objectOverrides )
{
    $getDatabaseBackupStatusParams.($objectOverride.Parameter) = $objectOverride.Value
}

# Call the Get-DatabaseBackupStatus.ps1 script
if ( -not $TestRun )
{
    & '$FileResource[Name="SqlServerSupplemental.GetDatabaseBackupStatus"]/Path$' @getDatabaseBackupStatusParams
}
else
{
    $getDatabaseBackupStatusPath = Join-Path -Path $PSScriptRoot -ChildPath Get-DatabaseBackupStatus.ps1
    & $getDatabaseBackupStatusPath @getDatabaseBackupStatusParams
}

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
