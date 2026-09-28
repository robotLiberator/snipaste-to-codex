---
name: install-snipaste-to-codex
description: Install, update, verify, or uninstall the Snipaste-to-Codex Windows bridge. Use for silent annotated-screenshot queuing or a global mouse side button that toggles Codex dictation without foreground switching. Do not use on macOS or Linux.
---

# Install Snipaste To Codex

Set up the per-user Windows bridge from `robotLiberator/snipaste-to-codex`. Keep the installation small and do not substitute AutoHotkey, browser extensions, third-party Snipaste mirrors, or Codex private interfaces.

## Preflight

1. Confirm the host is Windows and that the Codex desktop app is installed.
2. Check whether Snipaste is already installed or running. Look for the `Snipaste` process, `Snipaste.exe` on `PATH`, and ordinary per-user installation locations. Do not require a particular installation path.
3. If Snipaste 2.x is missing, tell the user that it is free for personal, non-commercial use and requires an appropriate license for commercial use. Install only after the user confirms that this licensing is acceptable.

## Install Snipaste when missing

Prefer the Windows Package Manager community package, which points to the publisher's official download:

```powershell
winget install --id liule.Snipaste --exact --source winget --accept-source-agreements --accept-package-agreements
```

If `winget` is unavailable or the exact package cannot be verified, open `https://www.snipaste.com/download.html` and ask the user to install the matching Windows architecture from the official publisher. Do not download from mirrors. Resume after `Snipaste.exe` is available, then start it once so its default `F1` screenshot hotkey is active.

## Install the bridge

Use a repository-local `SnipasteToCodex.ps1` when the skill was obtained with the repository. It is located two directories above this `SKILL.md`. If that file is unavailable, download only this raw URL to a temporary file:

`https://raw.githubusercontent.com/robotLiberator/snipaste-to-codex/main/SnipasteToCodex.ps1`

Never pipe a remote script directly into `Invoke-Expression`. Save it first, confirm that it is a PowerShell script from the expected HTTPS origin, inspect its install/uninstall parameter block, and then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <path-to-SnipasteToCodex.ps1> -Install
```

The installer must remain per-user. Do not request administrator rights, weaken execution policy globally, or alter Windows security settings.

The script compiles its embedded C# source with the Windows-provided .NET Framework compiler and installs a small standalone `SnipasteToCodex.exe`. PowerShell is used only during installation, self-test, update, and removal; it must not remain as the background bridge.

## Verify

Run the same script with `-SelfTest` and require all of the following:

- `CodexRunning` is true while Codex is open.
- `SnipasteRunning` is true.
- `QueueWritable` is true.
- `LightweightExeReady` is true.
- `BackgroundRunning` is true, with the installed `SnipasteToCodex.exe` running under `%LOCALAPPDATA%\SnipasteToCodex` and no persistent PowerShell bridge.
- The startup shortcut exists in the current user's Startup folder.
- `DictationControlFound` is true while Codex is showing a chat composer. This check only discovers the control and must not start the microphone.

If verification fails, report the failed check and retry only the corresponding step once. Do not repeatedly reinstall everything.

Explain the final behavior: `F1` starts Snipaste; clicking copy/finish silently queues the annotated image; the bridge never brings Codex forward; queued images paste in order when the user returns to Codex; screenshots alone do not send a message automatically. The mouse forward side button (`XButton2`) starts the real Codex dictation control globally by default; pressing it again invokes Codex's “transcribe and send” action. The user can right-click the tray icon to select the back side button (`XButton1`) or disable voice control. Codex must be running on a chat page, and first-use microphone permission may still require interaction.

## Update or uninstall

For an update, obtain the current repository script and run `-Install` again. Preserve queued images.

For removal, run the installed or downloaded script with `-Uninstall`. This removes the bridge and its startup entry. Do not remove Snipaste unless the user separately and explicitly asks for it.
