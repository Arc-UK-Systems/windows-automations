# Changelog

All notable changes to `Save-PreMigrationConfig.ps1` and `Remove-VMwareTools.ps1`. Each script versions independently.

## [Unreleased]

### Added
- Brought both scripts into the repository, unchanged from the versions already in use on migrations:
  - `Save-PreMigrationConfig.ps1` v1.0: records the VM's network, persistent routes, disks, volumes and VMware Tools install before migration, to `C:\ProgramData\Arc\Migration\pre-migration.json` and `.txt`.
  - `Remove-VMwareTools.ps1` v2.0: on Hyper-V, disables the VMware-only steps (`VM_CheckRequirements`, `VM_LogStart`, `VM_UninstGHIRestGuestHandle`) in the cached VMware Tools installer so the uninstall no longer rolls back with 1603, backs up and restores the cached installer on failure, then checks the VM against the pre-migration capture. `-Inspect` is read-only; `-Restart` restarts after a successful uninstall.
- `Save-PreMigrationConfig.ps1` v1.1: records the firmware type and the Hyper-V boot drivers `vmbus` and `storvsc`, with any `StartOverride` values, in a new "Hyper-V boot drivers (MT-001)" section of `pre-migration.txt` and as `Firmware`, `BootDrivers` and `BootDriverFixNeeded` in `pre-migration.json`. A `StartOverride` demotes the driver to on demand and stops the VM booting on Hyper-V with `INACCESSIBLE_BOOT_DEVICE`, so the script ends with a red ACTION REQUIRED line when one is found, or a green line when none is. Still read-only: the fix stays a separate, deliberate step (MT-001 in the Migration troubleshooting guide).
- `Remove-VMwareTools.ps1` v2.1.0: also uninstalls the VMware vCenter Converter Standalone agent when it is installed (DCER-DATA01 had 6.3.0, left over from converting the server). It has no use on Hyper-V and runs as a network-listening LocalSystem service. The uninstall is an ordinary silent one with its own log, `Converter-uninstall-<time>.log`; a failure is a warning and doesn't affect the VMware Tools result. `-Inspect` says whether it would be removed. A restart is suggested if the Converter uninstall asks for one.
- Download-then-run one-liners in the README and both script headers. They force TLS 1.2, save the script to `C:\ProgramData\Arc\Migration\` and run it from there. `irm | iex` isn't used because the scripts' `exit` would close the console and the switches couldn't be passed. Copying the script to the VM by hand remains the fallback when the VM has no internet.

### Fixed
- `Remove-VMwareTools.ps1` v2.0.1: VMware-only steps are now matched by the name before any `.<module GUID>` suffix. In VMware Tools 12.x, `VM_UninstGHIRestGuestHandle` comes from a merge module and is named `VM_UninstGHIRestGuestHandle.869A7E00_8665_0000_83A8_EF0F76CF0001`, so v2.0's exact match missed it, left it enabled, and the uninstall rolled back with 1603 at "Restoring guest handlers" (seen on a Dedman Gray VM with VMware Tools 12.5.4). Other suffixed actions such as `VM_UninstVMToolsSv.*` are still left alone.
- `Remove-VMwareTools.ps1` v2.0.2: also skips `VM_UninstallPerUserHgfs`. With v2.0.1 the same VM (a domain controller) got further, then this step returned 1603 and rolled the whole uninstall back. It only tidies per-user Shared Folders settings after `VM_UninstallHgfsDrv` has removed the HGFS driver, which still runs; skipping it can leave harmless per-user Shared Folders entries.
- `Remove-VMwareTools.ps1` v2.0.3: new `-ProductCode {GUID}` removes one VMware Tools product when Windows lists more than one. DGPC-RDS01 had both 12.5.4 and an earlier 12.3.5 registered as installed (Windows Installer state 5, each with its own cached installer, same install folder), so the script stopped. Without `-ProductCode` it still stops, now listing the newest version first and saying what to run. Remove the newest first, restart, then run again for the older one.

### Changed
- **Repository moved to the `Arc-UK-Systems` organisation and renamed `windows-automations`.** The download one-liners now point at `https://raw.githubusercontent.com/Arc-UK-Systems/windows-automations/main/...`. GitHub redirects the old `Arc-hub-tech/Automations` URLs, so a one-liner saved elsewhere keeps working, but it now depends on that redirect - use the new URL.
