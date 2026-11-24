# VMware to Hyper-V migration

Two scripts run inside a Windows VM being moved from VMware to Hyper-V: one before the move,
one after. Together they record how the VM was set up, remove VMware Tools once the VM is on
Hyper-V, and check that nothing was lost on the way.

**Status:** In use on migrations. Each script versions independently; check its header comment
for its current version.

| Script | When | Changes anything? | Purpose |
| --- | --- | --- | --- |
| `Save-PreMigrationConfig.ps1` | Before migration, on VMware | No (writes its report files only) | Records network, routes, disks, volumes and the VMware Tools install; flags `StartOverride` on the Hyper-V boot drivers |
| `Remove-VMwareTools.ps1` | After migration, on Hyper-V | Yes (uninstalls VMware Tools and the vCenter Converter agent) | Removes VMware Tools and any leftover vCenter Converter Standalone agent, then compares the VM with the pre-migration capture |

Both refuse to run unless elevated, and each refuses to run on the wrong platform
(`Save-PreMigrationConfig.ps1` only on VMware, `Remove-VMwareTools.ps1` only on Hyper-V).

## Steps

Each step has a one-liner that downloads the script to `C:\ProgramData\Arc\Migration\` and runs
it. Paste it as a **single line** (a multi-line paste breaks in the console) into an
**elevated** Windows PowerShell. It forces TLS 1.2 first, which Windows PowerShell on Server
2012 R2/2016 doesn't use by default and GitHub requires.

Don't pipe the scripts with `irm | iex`: their `exit` on a STOP would close the console before
you can read why, and `-Inspect`/`-Restart` can't be passed. Without internet on the VM, copy
the script over and run it with `powershell.exe -ExecutionPolicy Bypass -File .\<script>.ps1`.

1. **On VMware, before the move**, run `Save-PreMigrationConfig.ps1`:

   ```powershell
   [Net.ServicePointManager]::SecurityProtocol='Tls12'; $p="$env:ProgramData\Arc\Migration\Save-PreMigrationConfig.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-UK-Systems/windows-automations/main/vmware-migration/Save-PreMigrationConfig.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p
   ```

   It writes to `C:\ProgramData\Arc\Migration\`:
   - `pre-migration.json`, which `Remove-VMwareTools.ps1` reads after the move;
   - `pre-migration.txt`, a readable copy for the migration ticket.

   An earlier capture is renamed with a timestamp, never overwritten.

   If it ends with a red **ACTION REQUIRED (MT-001)**, `vmbus` or `storvsc` has a
   `StartOverride` that will stop the VM booting on Hyper-V. Run the MT-001 fix before the final
   shutdown, then shut the VM down rather than restarting it: Windows writes `StartOverride`
   again at startup.

2. **Migrate the VM.**

3. **On Hyper-V, after the move**, run `Remove-VMwareTools.ps1`. The VM needs internet for the
   one-liner; if the move lost a static IP, copy the script over instead. Look first with
   `-Inspect`, which changes nothing:

   ```powershell
   [Net.ServicePointManager]::SecurityProtocol='Tls12'; $p="$env:ProgramData\Arc\Migration\Remove-VMwareTools.ps1"; md (Split-Path $p) -Force|Out-Null; irm https://raw.githubusercontent.com/Arc-UK-Systems/windows-automations/main/vmware-migration/Remove-VMwareTools.ps1 -OutFile $p; Set-ExecutionPolicy Bypass -Scope Process -Force; & $p -Inspect
   ```

   Then remove VMware Tools by running the saved copy (add `-Restart` to restart 15 seconds
   after a successful uninstall):

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force; & "$env:ProgramData\Arc\Migration\Remove-VMwareTools.ps1"
   ```

4. Work through any warnings in the summary, then restart the VM if you didn't use `-Restart`.

## Datto RMM: prepare in advance

`Invoke-ArcMigrationPrep.ps1` is a Datto RMM component (Script, PowerShell, Windows) that does
Step 1 and the MT-001 fix ahead of time and automates Step 3. Paste it into the component; attach
the three scripts below as an optional fallback for when GitHub can't be reached. Run it on each
VM to be migrated while it is still on VMware. The component itself never restarts the VM.

1. Saves `Save-PreMigrationConfig.ps1`, `Remove-VMwareTools.ps1` and
   `Invoke-ArcMigrationBootTask.ps1` to `C:\ProgramData\Arc\Migration\` (from `usrBranch`).
2. Runs `Save-PreMigrationConfig.ps1`; stops if it fails.
3. Applies the MT-001 fix. The first backup of each key is kept as
   `<service>-StartOverride-backup.reg`, so the MT-001 rollback still restores the original
   values; later backups get a timestamp.
4. Registers the scheduled task `\Arc\VMware to Hyper-V migration` (SYSTEM, at startup, 3
   minutes' delay) running `Invoke-ArcMigrationBootTask.ps1`:
   - **on VMware**, deletes `StartOverride` again at every startup, because Windows writes it
     back. After a restart on VMware, wait 3 minutes before the final backup;
   - **on Hyper-V**, runs `Remove-VMwareTools.ps1` from the local copy (no network needed).
     With two VMware Tools products (MT-010) it removes the newest, and the next startup removes
     the next. When nothing VMware is left the task unregisters itself. A startup that removes
     nothing counts as a failed attempt; after 3 the task unregisters itself and Step 7 is
     finished by hand (MT-009, MT-004). A failed attempt does not restart the VM.

| Variable | Default | Meaning |
| --- | --- | --- |
| `usrBranch` | `main` | Git branch the scripts are fetched from |
| `usrCancel` | `false` | Migration called off: removes the task only |

After each removal the task shows a message to everyone signed in (`msg.exe`, 30 seconds),
then restarts the VM 30 seconds later. This happens on the first Hyper-V startup too, while
Veeam is still running the VM from Instant Recovery; a restart there can be slow (MT-005).
With two products, each startup removes one and restarts, so expect two restarts.

Log: `C:\ProgramData\Arc\Migration\boot-task.log`, plus the full output of each removal in
`Remove-VMwareTools-<time>.txt`.

## Why VMware Tools needs a workaround on Hyper-V

The VMware Tools uninstaller runs a hardware check (`VM_CheckRequirements`) that fails on any
other hypervisor, so a normal uninstall on Hyper-V rolls back with error 1603 (Broadcom KB
414772). `Remove-VMwareTools.ps1`:

1. finds the cached VMware Tools installer Windows uses for the uninstall
   (`C:\Windows\Installer\*.msi`) and backs it up to `C:\ProgramData\Arc\Migration`, checking the
   copy by hash;
2. disables only the VMware-only steps in the cached installer by setting their condition to `0`:
   `VM_CheckRequirements`, `VM_LogStart`, `VM_UninstGHIRestGuestHandle`;
3. runs the normal silent uninstall (`msiexec /x <product code> /qn /norestart`) with a verbose
   log in `C:\ProgramData\Arc\Migration\`;
4. if the uninstall fails, puts the original cached installer back;
5. uninstalls the VMware vCenter Converter Standalone agent if it is installed. It is left over
   from converting the server, has no use on Hyper-V and runs as a LocalSystem service listening
   on the network. Its uninstall is an ordinary one, logged to `Converter-uninstall-<time>.log`.

`-Inspect` shows the cached installer, the steps that would be disabled and whether the Converter
agent would be uninstalled, then stops without
changing anything.

## Post-migration checks

After the uninstall, `Remove-VMwareTools.ps1` reports, without changing anything:

- VMware entries and services still present;
- Hyper-V integration services (heartbeat, shutdown, time sync and KVP must be running);
- network adapters now, beside the pre-migration capture, with a warning for any static IPv4
  address that is no longer configured on any adapter;
- persistent static routes from before the move, to check by hand;
- offline or read-only disks;
- drive letters that existed before the move but are missing now (CD/DVD drives are skipped);
- old VMware network devices (`vmxnet`) still registered.

Without a `pre-migration.json` the network and drive comparisons are skipped, with a warning.

## Files written

All in `C:\ProgramData\Arc\Migration\` on the VM:

| File | Written by |
| --- | --- |
| `pre-migration.json`, `pre-migration.txt` | `Save-PreMigrationConfig.ps1` |
| `pre-migration-<time>.json/.txt` | `Save-PreMigrationConfig.ps1`, when an earlier capture is kept |
| `<cached msi>-<time>.original` | `Remove-VMwareTools.ps1`, backup of the cached installer |
| `VMwareTools-uninstall-<time>.log` | `Remove-VMwareTools.ps1`, msiexec verbose log |
| `Converter-uninstall-<time>.log` | `Remove-VMwareTools.ps1`, msiexec verbose log for the Converter agent |
| `vmbus/storvsc-StartOverride-backup*.reg` | `Invoke-ArcMigrationPrep.ps1` and the startup task, MT-001 backups |
| `boot-task.log`, `boot-task-state.json`, `Remove-VMwareTools-<time>.txt` | `Invoke-ArcMigrationBootTask.ps1` |

These files describe the customer's network. Keep them out of this repository.

See `CHANGELOG.md` for version history.
