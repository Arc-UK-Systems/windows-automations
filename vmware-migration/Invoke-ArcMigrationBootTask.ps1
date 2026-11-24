<#
.SYNOPSIS
  Runs at every startup from the "\Arc\VMware to Hyper-V migration" scheduled task that the
  Datto component Invoke-ArcMigrationPrep.ps1 registers. Not meant to be run by hand.
  Arc Systems - VMware to Hyper-V migrations. Version 1.0

.DESCRIPTION
  Works out where the VM is running and does only what fits:

  On VMware (before the move)
    Removes StartOverride from the Hyper-V boot drivers vmbus and storvsc again (MT-001).
    Windows writes it back at every startup, so the fix the component made would otherwise be
    gone after any restart between the prep run and the migration. Each key is backed up with
    reg.exe first; the first backup of each key is kept as <service>-StartOverride-backup.reg
    (the rollback in MT-001), later ones get a timestamp.

  On Hyper-V (after the move)
    Runs Remove-VMwareTools.ps1 from C:\ProgramData\Arc\Migration, which the component saved
    there before the move, so it works even when the VM has no network yet.
      - One VMware Tools product: removes it (and the vCenter Converter agent if present).
      - Two or more (MT-010): removes the newest only. The task stays, and the next startup
        removes the next one.
      - When nothing VMware is left, the task unregisters itself.
    Restart after a removal depends on -RebootMode:
      Auto    No restart on the first Hyper-V startup (normally Veeam Instant Recovery, where a
              restart before Migrate to production can take over an hour - MT-005). On later
              startups, restarts when a removal finished.
      Always  Restarts after every removal, first startup included. Use when the VM is restored
              straight to production storage, not run from Instant Recovery.
      Never   Never restarts; the engineer restarts.
    A run that removes nothing counts as a failed attempt. After -MaxAttempts failed attempts
    the task unregisters itself so a broken uninstall can't repeat at every startup; follow
    MT-009 / MT-004 by hand from there.

  Anything else: logs the platform and changes nothing.

  Log: C:\ProgramData\Arc\Migration\boot-task.log (appended), and the full output of each
  removal in Remove-VMwareTools-<time>.txt beside it.
#>
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Always', 'Never')][string]$RebootMode = 'Auto',
    [ValidateRange(1, 10)][int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '1.0'
$dir       = 'C:\ProgramData\Arc\Migration'
$logFile   = Join-Path $dir 'boot-task.log'
$stateFile = Join-Path $dir 'boot-task-state.json'
$remover   = Join-Path $dir 'Remove-VMwareTools.ps1'
$TaskName  = 'VMware to Hyper-V migration'
$TaskPath  = '\Arc\'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
function Write-Log([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line   # not Write-Output: that would leak into the return value of the function calling Write-Log
}

function Remove-MigrationTask {
    if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        Write-Log "Scheduled task $TaskPath$TaskName removed."
    }
}

# ---------------- MT-001 fix ----------------
# KEEP IN SYNC with Remove-StartOverride in Invoke-ArcMigrationPrep.ps1.
# Backs up and deletes StartOverride on vmbus and storvsc. Returns one line per service.
# The first backup of each key is kept under the fixed name the MT-001 rollback uses, so a
# later run never overwrites the original values; later backups get a timestamp.
function Remove-StartOverride([string]$BackupDir) {
    foreach ($s in 'vmbus', 'storvsc') {
        $key = "HKLM\SYSTEM\CurrentControlSet\Services\$s\StartOverride"
        if (-not (Test-Path "Registry::$key")) { "$s - no StartOverride, nothing to do"; continue }
        $bak = Join-Path $BackupDir "$s-StartOverride-backup.reg"
        if (Test-Path $bak) { $bak = Join-Path $BackupDir ("$s-StartOverride-backup-{0}.reg" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
        & reg.exe export $key $bak /y 2>&1 | Out-Null
        if (-not (Test-Path $bak) -or (Get-Item $bak).Length -eq 0) { "STOP - $s - backup of $key failed, StartOverride left in place"; continue }
        & reg.exe delete $key /f 2>&1 | Out-Null
        if (Test-Path "Registry::$key") { "STOP - $s - could not delete $key (backup $bak)" }
        else { "$s - StartOverride removed (backup $bak)" }
    }
}

function Get-VMwareEntries {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $all = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue)
    [pscustomobject]@{
        Tools     = @($all | Where-Object { $_.DisplayName -eq 'VMware Tools' })
        Converter = @($all | Where-Object { $_.DisplayName -like 'VMware vCenter Converter Standalone*' -and $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' })
    }
}

function Get-State {
    $s = [pscustomobject]@{ HyperVBoots = 0; FailedAttempts = 0 }
    if (Test-Path $stateFile) {
        try {
            $j = Get-Content $stateFile -Raw | ConvertFrom-Json
            $s.HyperVBoots    = [int]$j.HyperVBoots
            $s.FailedAttempts = [int]$j.FailedAttempts
        } catch { Write-Log "State file unreadable, starting from zero: $($_.Exception.Message)" }
    }
    $s
}
function Save-State($s) { $s | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8 }

# Runs Remove-VMwareTools.ps1 in its own process and keeps its whole output.
function Invoke-Remover([string[]]$ExtraArgs) {
    $out = Join-Path $dir "Remove-VMwareTools-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $remover) + $ExtraArgs
    $text = & powershell.exe @argList 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $text | Set-Content -Path $out -Encoding UTF8
    Write-Log "Remove-VMwareTools.ps1 $($ExtraArgs -join ' ') exited $code. Output: $out"
    [pscustomobject]@{ ExitCode = $code; Text = ($text -join "`n"); OutFile = $out }
}

try {
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Log "Invoke-ArcMigrationBootTask.ps1 v$ScriptVersion - $env:COMPUTERNAME - $($cs.Manufacturer) / $($cs.Model) - RebootMode $RebootMode"

    # ================= Still on VMware: keep the MT-001 fix in place =================
    if ($cs.Manufacturer -like 'VMware*') {
        foreach ($l in (Remove-StartOverride -BackupDir $dir)) { Write-Log "MT-001: $l" }
        exit 0
    }

    # ================= Not Hyper-V either: do nothing =================
    if (-not ($cs.Manufacturer -eq 'Microsoft Corporation' -and $cs.Model -eq 'Virtual Machine')) {
        Write-Log 'Neither VMware nor Hyper-V. Nothing changed.'
        exit 0
    }

    # ================= On Hyper-V: remove VMware Tools =================
    $state = Get-State
    $state.HyperVBoots++
    Save-State $state
    Write-Log "Hyper-V startup number $($state.HyperVBoots) since the prep run."

    $before = Get-VMwareEntries
    if ($before.Tools.Count -eq 0 -and $before.Converter.Count -eq 0) {
        Write-Log 'No VMware Tools or vCenter Converter agent installed. Migration clean-up complete.'
        Remove-MigrationTask
        exit 0
    }
    if (-not (Test-Path $remover)) {
        Write-Log "STOP - $remover is missing. Run the removal by hand (Step 7). Task removed."
        Remove-MigrationTask
        exit 1
    }

    # Two or more VMware Tools products (MT-010): newest first, the next on the next startup
    $extra = @()
    if ($before.Tools.Count -gt 1) {
        $newest = $before.Tools | Sort-Object { [version](($_.DisplayVersion -replace '[^0-9.]', '').Trim('.')) } -Descending | Select-Object -First 1
        $extra = @('-ProductCode', $newest.PSChildName)
        Write-Log "$($before.Tools.Count) VMware Tools products registered (MT-010). Removing the newest, $($newest.DisplayVersion) $($newest.PSChildName), this startup."
    } else {
        foreach ($t in $before.Tools)     { Write-Log "Removing VMware Tools $($t.DisplayVersion) $($t.PSChildName)." }
        foreach ($c in $before.Converter) { Write-Log "Removing $($c.DisplayName) $($c.DisplayVersion)." }
    }

    $r = Invoke-Remover $extra
    # 1618: another installation was running (devices still being set up after the move). Wait once and retry.
    if ($r.Text -match 'exit code 1618') {
        Write-Log 'Another installation was in progress (1618). Waiting 5 minutes, then trying once more.'
        Start-Sleep -Seconds 300
        $r = Invoke-Remover $extra
    }

    $after = Get-VMwareEntries
    $removed = ($after.Tools.Count -lt $before.Tools.Count) -or ($after.Converter.Count -lt $before.Converter.Count)
    if (-not $removed) {
        $state.FailedAttempts++
        Save-State $state
        Write-Log "FAILED - nothing was removed (attempt $($state.FailedAttempts) of $MaxAttempts). See $($r.OutFile) and the msiexec log beside it; MT-009 (1603) and MT-004 (hang at VM_StopRunningServices) cover the known causes."
        if ($state.FailedAttempts -ge $MaxAttempts) {
            Write-Log "Giving up after $MaxAttempts failed attempts. Finish Step 7 by hand."
            Remove-MigrationTask
        } else {
            Write-Log 'Will try again at the next startup. No restart from this task.'
        }
        exit 1
    }

    $state.FailedAttempts = 0
    Save-State $state
    $warn = @($r.Text -split "`n" | Where-Object { $_ -like 'WARNING - *' })
    if ($warn.Count) { foreach ($w in $warn) { Write-Log "Summary: $w" } } else { Write-Log 'Summary: No warnings.' }

    if ($after.Tools.Count -eq 0 -and $after.Converter.Count -eq 0) {
        Write-Log 'All VMware Tools and Converter entries removed.'
        Remove-MigrationTask
    } else {
        $left = @($after.Tools | ForEach-Object { "VMware Tools $($_.DisplayVersion)" }) + @($after.Converter | ForEach-Object { $_.DisplayName })
        Write-Log "Still registered: $($left -join '; '). The task stays and removes the next one at the next startup."
    }

    $doRestart = switch ($RebootMode) {
        'Always' { $true }
        'Never'  { $false }
        default  { $state.HyperVBoots -gt 1 }
    }
    if ($doRestart) {
        Write-Log 'Restarting in 60 seconds to finish the removal.'
        & shutdown.exe /r /t 60 /d p:4:2 /c 'Arc migration: restarting to finish removing VMware Tools.' | Out-Null
    } elseif ($RebootMode -eq 'Auto') {
        Write-Log 'First Hyper-V startup: not restarting (MT-005). Restart after Migrate to production has finished.'
    } else {
        Write-Log 'RebootMode Never: restart the VM when convenient to finish the removal.'
    }
    exit 0
}
catch {
    Write-Log "ERROR - $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}
