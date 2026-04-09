<#
.SYNOPSIS
    Generates ready-to-import Windows Task Scheduler files for QuotaGroup Planning.

.DESCRIPTION
    Creates Task Scheduler XML definitions and a helper import script for:
    - Hourly baseline capture (history + candidates)
    - Daily quota-group planning (discover + plan against target group)

    This script does not register tasks by default. It generates importable artifacts.

.EXAMPLE
    .\tools\New-QuotaPlanningScheduledTasks.ps1

.EXAMPLE
    .\tools\New-QuotaPlanningScheduledTasks.ps1 -ManagementGroupId SharedCapacityDemo -GroupQuotaName groupquota1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Repository root path containing Get-AzVMAvailability.ps1")]
    [string]$RepositoryPath = (Split-Path -Parent $PSScriptRoot),

    [Parameter(Mandatory = $false, HelpMessage = "Output folder for generated task files")]
    [string]$OutputPath,

    [Parameter(Mandatory = $false, HelpMessage = "Task name prefix")]
    [string]$TaskPrefix = "AzVMAvailability",

    [Parameter(Mandatory = $false, HelpMessage = "Region preset to use for scheduled scans")]
    [string]$RegionPreset = "USMajor",

    [Parameter(Mandatory = $false, HelpMessage = "Target management group name for daily planning")]
    [string]$ManagementGroupId = "SharedCapacityDemo",

    [Parameter(Mandatory = $false, HelpMessage = "Target quota group name for daily planning")]
    [string]$GroupQuotaName = "groupquota1",

    [Parameter(Mandatory = $false, HelpMessage = "Hour (0-23) to run the daily plan task")]
    [ValidateRange(0, 23)]
    [int]$DailyPlanHour = 6
)

$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $OutputPath = Join-Path $RepositoryPath "artifacts\scheduled-tasks"
}

if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
    throw "RepositoryPath not found: $RepositoryPath"
}

$mainScript = Join-Path $RepositoryPath "Get-AzVMAvailability.ps1"
if (-not (Test-Path -LiteralPath $mainScript -PathType Leaf)) {
    throw "Could not find script at: $mainScript"
}

if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

function Get-IsoBoundaryFromNow {
    param(
        [int]$OffsetMinutes = 2
    )

    $start = (Get-Date).AddMinutes($OffsetMinutes)
    return $start.ToString("yyyy-MM-ddTHH:mm:ss")
}

function New-TaskXml {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$StartBoundary,
        [Parameter(Mandatory = $true)][string]$ScheduleXml,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$UserId
    )

    $escCommand = [System.Security.SecurityElement]::Escape($Command)
    $escArgs = [System.Security.SecurityElement]::Escape($Arguments)
    $escWorkDir = [System.Security.SecurityElement]::Escape($WorkingDirectory)
    $escDesc = [System.Security.SecurityElement]::Escape($Description)
    $escUser = [System.Security.SecurityElement]::Escape($UserId)

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$escDesc</Description>
  </RegistrationInfo>
  <Triggers>
$ScheduleXml
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escCommand</Command>
      <Arguments>$escArgs</Arguments>
      <WorkingDirectory>$escWorkDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$pwshCmd = "pwsh.exe"
$repoPathResolved = (Resolve-Path -LiteralPath $RepositoryPath).Path
$mainScriptResolved = (Resolve-Path -LiteralPath $mainScript).Path

$hourlyArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$mainScriptResolved`" -NoPrompt -AllSubscriptions -RegionPreset `"$RegionPreset`" -CaptureQuotaHistory -QuotaGroupCandidates"
$dailyPlanArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$mainScriptResolved`" -NoPrompt -AllSubscriptions -RegionPreset `"$RegionPreset`" -QuotaGroupCandidates -QuotaGroupPlan -QuotaGroupDiscover -QuotaGroupManagementGroupId `"$ManagementGroupId`" -QuotaGroupName `"$GroupQuotaName`""

$hourlyStart = Get-IsoBoundaryFromNow -OffsetMinutes 2
$dailyStart = (Get-Date).Date.AddHours($DailyPlanHour)
if ($dailyStart -lt (Get-Date)) {
    $dailyStart = $dailyStart.AddDays(1)
}
$dailyStartIso = $dailyStart.ToString("yyyy-MM-ddTHH:mm:ss")

$hourlySchedule = @"
    <TimeTrigger>
      <StartBoundary>$hourlyStart</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT1H</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
"@

$dailySchedule = @"
    <CalendarTrigger>
      <StartBoundary>$dailyStartIso</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
"@

$hourlyTaskName = "$TaskPrefix-Hourly-Baseline"
$dailyTaskName = "$TaskPrefix-Daily-Plan"

$hourlyXml = New-TaskXml -Description "Get-AzVMAvailability hourly baseline capture for quota history and candidates" -StartBoundary $hourlyStart -ScheduleXml $hourlySchedule -Command $pwshCmd -Arguments $hourlyArgs -WorkingDirectory $repoPathResolved -UserId $userId
$dailyXml = New-TaskXml -Description "Get-AzVMAvailability daily quota-group plan generation" -StartBoundary $dailyStartIso -ScheduleXml $dailySchedule -Command $pwshCmd -Arguments $dailyPlanArgs -WorkingDirectory $repoPathResolved -UserId $userId

$hourlyXmlPath = Join-Path $OutputPath "$hourlyTaskName.xml"
$dailyXmlPath = Join-Path $OutputPath "$dailyTaskName.xml"
$importScriptPath = Join-Path $OutputPath "Import-QuotaPlanningScheduledTasks.ps1"

Set-Content -LiteralPath $hourlyXmlPath -Value $hourlyXml -Encoding Unicode
Set-Content -LiteralPath $dailyXmlPath -Value $dailyXml -Encoding Unicode

$importScript = @"
`$ErrorActionPreference = 'Stop'

`$hourlyXml = "$hourlyXmlPath"
`$dailyXml = "$dailyXmlPath"

schtasks /Create /TN "$hourlyTaskName" /XML `"`$hourlyXml`" /F
schtasks /Create /TN "$dailyTaskName" /XML `"`$dailyXml`" /F

Write-Host "Imported tasks:" -ForegroundColor Green
Write-Host "  $hourlyTaskName" -ForegroundColor Cyan
Write-Host "  $dailyTaskName" -ForegroundColor Cyan
"@

Set-Content -LiteralPath $importScriptPath -Value $importScript -Encoding UTF8

Write-Host "Generated Task Scheduler artifacts:" -ForegroundColor Green
Write-Host "  Hourly XML: $hourlyXmlPath" -ForegroundColor Cyan
Write-Host "  Daily XML:  $dailyXmlPath" -ForegroundColor Cyan
Write-Host "  Import PS1: $importScriptPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1) Review XML files" -ForegroundColor Gray
Write-Host "  2) Import with: powershell -ExecutionPolicy Bypass -File `"$importScriptPath`"" -ForegroundColor Gray
Write-Host "  3) Verify in Task Scheduler UI" -ForegroundColor Gray
