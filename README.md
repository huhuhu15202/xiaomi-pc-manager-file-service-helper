# Xiaomi PC Manager File Service Helper (Experimental)

This PowerShell helper exposes and enables the built-in **File Service** feature in a compatible Xiaomi PC Manager installation. The phone-side feature lets a paired Xiaomi or REDMI phone/tablet manage files on the PC.

The helper edits a small, version-specific part of Xiaomi PC Manager's local JavaScript bundle. It reveals the hidden setting and checks the service state when the manager starts, calling the manager's existing `set_remote_file_manager_state` handler only when the service is off. It does not implement a replacement file-transfer protocol.

## Important access notice

Enabling File Service can make local PC volumes available to the paired phone. In the tested build, the manager adds eligible local volume roots to its sharing configuration, so access may extend beyond the usual Desktop, Documents, or Downloads folders. The exact volumes vary by PC. Windows access controls and the Xiaomi pairing flow still apply, but do not rely on them as the only protection. Run this only if you want the paired device to browse PC files.

The script requires an explicit `-AcknowledgeAllLocalDrives` parameter before enabling. It does not upload files, logs, or machine details. It stores a local backup under `%ProgramData%` so the patch can be removed.

## Requirements and compatibility

- Windows PowerShell on Windows 10 or 11.
- Administrator rights, because the manager bundle is under `Program Files` and the app must be restarted when the service is off.
- Xiaomi PC Manager **5.8.1.121** is the build validated for the current patch signatures. The script checks its expected code anchors and stops without editing if they do not match. Other builds are not confirmed.
- A compatible Xiaomi phone/tablet setup is still required for phone-side discovery and file access.

This is an experimental, unofficial compatibility patch. Xiaomi PC Manager updates may replace the modified bundle; run the helper again after an update only if its compatibility checks still pass.

## Usage

Open an elevated PowerShell in the directory containing the script, then run:

```powershell
.\Enable-XiaomiPCManagerFileService.ps1 -AcknowledgeAllLocalDrives
```

If the service is already listening, the default behavior leaves the current connection undisturbed and applies automatic enabling on the next manager start. Add `-Restart` to restart the manager now; this interrupts any active phone session:

```powershell
.\Enable-XiaomiPCManagerFileService.ps1 -AcknowledgeAllLocalDrives -Restart
```

To restore the original bundle from the local backup:

```powershell
.\Enable-XiaomiPCManagerFileService.ps1 -Restore
```

For a nonstandard installation directory, specify the version directory containing `XiaomiPcManager.exe`:

```powershell
.\Enable-XiaomiPCManagerFileService.ps1 -RequestedInstallPath 'C:\Program Files\MI\XiaomiPCManager\5.8.1.121' -AcknowledgeAllLocalDrives
```

The backup is stored at `%ProgramData%\MI\XiaomiPCManager\FileServiceHelper\<version>\main.js.original`.

## Validation

The off-to-on startup path was exercised on Xiaomi PC Manager 5.8.1.121: the setting returned to on and the manager logged a successful sharing-configuration update. That run did not expose a `SambaServer.exe` listener, so phone-side discovery and file access remain unverified. When the manager accepts the configuration but no listener is detected, the helper reports that limitation and asks you to confirm availability on the phone. This does not validate every phone model, account configuration, or future manager build.

## License

MIT. See [LICENSE](LICENSE).
