<#
    Invoke-ArcMigrationPrep.ps1
    Arc Systems - VMware to Hyper-V migrations

    DATTO RMM COMPONENT  -  Script (PowerShell), Windows, Devices
    Run on each VM to be migrated, while it is still on VMware, before the final backup.

    What it does
      1. Saves Save-PreMigrationConfig.ps1, Remove-VMwareTools.ps1 and
         Invoke-ArcMigrationBootTask.ps1 to C:\ProgramData\Arc\Migration (fetched from git on
         usrBranch; component file attachments are the fallback if GitHub can't be reached).
      2. Runs Save-PreMigrationConfig.ps1: pre-migration.json / .txt (Step 1 of the guide).
      3. Applies the MT-001 fix: backs up and deletes StartOverride on vmbus and storvsc.
      4. Registers the scheduled task \Arc\VMware to Hyper-V migration (SYSTEM, at startup,
         3 minutes' delay) running Invoke-ArcMigrationBootTask.ps1, which
           - on VMware, deletes StartOverride again at every startup (Windows writes it back),
             so a restart between this run and the migration doesn't undo step 3;
           - on Hyper-V, removes VMware Tools (Step 7, MT-010 handled one product per startup),
             restarts according to usrRebootMode, and unregisters itself when nothing VMware
             is left.
      It does not restart or shut the VM down.

    Component file attachments (optional - fallback only):
              Save-PreMigrationConfig.ps1, Remove-VMwareTools.ps1, Invoke-ArcMigrationBootTask.ps1

    Component input variables (all optional):
              usrBranch      String     default main   Git branch to fetch the scripts from
              usrRebootMode  Selection  default Auto   Auto | Always | Never
                             Auto   - no restart on the first Hyper-V startup (Veeam Instant
                                      Recovery: a restart before Migrate to production can take
                                      over an hour, MT-005); restarts on later startups when a
                                      removal finished
                             Always - restart after every removal (VM restored straight to
                                      production storage, no Instant Recovery)
                             Never  - the engineer restarts
              usrCancel      Boolean    default false  Migration called off: remove the
                                                       scheduled task only. Captures and
                                                       backups are kept.

    Exit code: 0 = prepared (or cancelled), 1 = failed (see output). The task is only
    registered when the capture succeeded.

    Version : 1.0
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$ScriptVersion = '1.0'
Write-Output "Invoke-ArcMigrationPrep.ps1 v$ScriptVersion - $env:COMPUTERNAME"

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Get-DattoString([string]$Name, [string]$Default) {
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw.Trim()
}
$Branch     = Get-DattoString 'usrBranch' 'main'
$RebootMode = Get-DattoString 'usrRebootMode' 'Auto'
$Cancel     = (Get-DattoString 'usrCancel' 'false') -match '^(true|1|yes)$'
if ($RebootMode -notin 'Auto', 'Always', 'Never') {
    Write-Output "FAILED - usrRebootMode '$RebootMode' is not Auto, Always or Never. Nothing changed."
    exit 1
}

$RepoRawBase = 'https://raw.githubusercontent.com/Arc-UK-Systems/windows-automations'
$dir      = 'C:\ProgramData\Arc\Migration'
$TaskName = 'VMware to Hyper-V migration'
$TaskPath = '\Arc\'
$Scripts  = 'Save-PreMigrationConfig.ps1', 'Remove-VMwareTools.ps1', 'Invoke-ArcMigrationBootTask.ps1'
$AttachDir = (Get-Location).Path   # Datto puts component attachments in the working directory

# ---------------- MT-001 fix ----------------
# KEEP IN SYNC with Remove-StartOverride in Invoke-ArcMigrationBootTask.ps1.
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

# Fetches one script from git (3 tries), else uses the component attachment. The result must
# parse as PowerShell before it replaces anything in $dir.
function Get-MigrationScript([string]$Name) {
    $dest = Join-Path $dir $Name
    $tmp  = "$dest.download"
    $url  = "$RepoRawBase/$Branch/vmware-migration/$Name"
    $source = $null
    for ($i = 1; $i -le 3 -and -not $source; $i++) {
        try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 30; $source = "git ($Branch)" }
        catch { if ($i -lt 3) { Start-Sleep -Seconds 5 } else { Write-Output "WARNING - fetch of $url failed: $($_.Exception.Message)" } }
    }
    if (-not $source) {
        $att = Join-Path $AttachDir $Name
        if (-not (Test-Path $att)) { throw "$Name could not be fetched from git and is not attached to the component." }
        Copy-Item $att $tmp -Force
        $source = 'component attachment'
    }
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs)
    if ((Get-Item $tmp).Length -eq 0 -or $errs.Count) {
        Remove-Item $tmp -Force
        throw "$Name from $source is empty or does not parse as PowerShell."
    }
    Move-Item $tmp $dest -Force
    Write-Output ("{0,-34} from {1}, SHA256 {2}" -f $Name, $source, (Get-FileHash $dest).Hash.Substring(0, 16))
}

try {
    # ---------------- Cancel ----------------
    if ($Cancel) {
        if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
            Write-Output "Removed scheduled task $TaskPath$TaskName. Captures and backups in $dir kept."
        } else { Write-Output 'No migration scheduled task present. Nothing changed.' }
        Write-Output 'Windows writes StartOverride back at the next startup, so the MT-001 fix needs no rollback.'
        exit 0
    }

    # ---------------- Must be on VMware ----------------
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.Manufacturer -notlike 'VMware*') {
        Write-Output "FAILED - this component is for VMs still on VMware. This device reports $($cs.Manufacturer) / $($cs.Model). Nothing changed."
        exit 1
    }

    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    # ---------------- 1. Scripts ----------------
    Write-Output ''
    Write-Output '=== 1. Scripts ==='
    foreach ($s in $Scripts) { Get-MigrationScript $s }

    # ---------------- 2. Capture ----------------
    Write-Output ''
    Write-Output '=== 2. Pre-migration capture ==='
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Save-PreMigrationConfig.ps1') 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    $out
    if ($rc -ne 0) { throw "Save-PreMigrationConfig.ps1 exited $rc. Task not registered." }

    # ---------------- 3. MT-001 fix ----------------
    Write-Output ''
    Write-Output '=== 3. MT-001 - Hyper-V boot drivers ==='
    $fix = @(Remove-StartOverride -BackupDir $dir)
    $fix
    if ($fix -like 'STOP*') { throw 'MT-001 fix incomplete - see above. Task not registered.' }

    # ---------------- 4. Scheduled task ----------------
    Write-Output ''
    Write-Output '=== 4. Startup task ==='
    $bootScript = Join-Path $dir 'Invoke-ArcMigrationBootTask.ps1'
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$bootScript`" -RebootMode $RebootMode"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT3M'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Arc VMware to Hyper-V migration: keeps the MT-001 fix on VMware; removes VMware Tools on Hyper-V, then removes itself.' -Force | Out-Null
    # A fresh prep starts the Hyper-V startup count and failed attempts from zero
    Remove-Item (Join-Path $dir 'boot-task-state.json') -Force -ErrorAction SilentlyContinue
    Write-Output "Registered $TaskPath$TaskName (SYSTEM, at startup + 3 min, RebootMode $RebootMode)."

    Write-Output ''
    Write-Output '=== Result ==='
    Write-Output 'PREPARED. Nothing was restarted.'
    Write-Output '- Copy pre-migration.txt (output above) into the migration ticket.'
    Write-Output '- If the VM restarts on VMware before the final backup, wait 3 minutes after startup so the task removes StartOverride again.'
    Write-Output '- On Hyper-V, VMware Tools is removed 3 minutes after the first startup. Log: C:\ProgramData\Arc\Migration\boot-task.log'
    exit 0
}
catch {
    Write-Output "FAILED - $($_.Exception.Message)"
    exit 1
}
