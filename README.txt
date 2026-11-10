NETWORK BACKUP MANAGER
======================

START
1. Extract the complete NetworkBackupManager folder on a Windows backup PC.
2. Confirm drive D: is available and the remote SMB shares are accessible.
3. Double-click START-BACKUP.bat.
4. Select a computer from the list.
5. Check only the folders you want to back up (for example, Desktop and Downloads).
6. Click START SELECTED BACKUP.

HOW IT WORKS
- Native Windows Forms application using Windows PowerShell 5.1; no Node.js, npm, or package.json is required.
- Only the selected computer and checked folders are included in the run.
- One hidden background PowerShell worker runs at a time. No CMD windows are opened.
- The next selected folder starts automatically after the current folder finishes.
- SMB TCP port 445 check: 3 attempts with a 10-second retry delay.
- Robocopy retries up to 3 times after a Robocopy failure.
- Stop, Resume, persistent per-job state, and logs are supported.
- Completed folders are skipped when resuming. Starting a new run resets completed state only for the newly selected folders.
- Robocopy uses /Z for restartable transfers.
- No /MIR or /PURGE; destination files are not automatically deleted.

REQUIREMENTS
- Windows 10/11 or Windows Server with Windows PowerShell 5.1.
- .NET Framework / Windows Forms available (included with supported Windows).
- Access to remote SMB shares and write access to the configured destination drive D:.
- TCP port 445 permitted between the backup PC and remote computers.

CONFIGURATION
Edit config\backup-jobs.json to change computer names, IP addresses, source paths, destination paths, enabled flags, retry settings, Robocopy arguments, or excluded file extensions. Existing 24 jobs across 9 computers are preserved.

STOP / RESUME
STOP BACKUP terminates the active worker process tree. Already copied files remain. RESUME SELECTED resumes the current selected folders; completed folders are skipped. Robocopy /Z supports restartable file transfers.

NOTES
- Authenticate to remote shares using Windows credentials if prompted. The app does not store passwords.
- A remote PC may be powered on but still fail the SMB check if file sharing or its firewall blocks TCP 445.
- Robocopy does not provide a reliable overall percentage for every folder tree. The GUI displays percentage output when Robocopy emits it; otherwise progress may remain at 0% while files are processed. Detailed Robocopy output is saved in the Logs folder.
- This is a native Windows PowerShell app. Do not run it in Google AI Studio's browser preview or install npm dependencies. Run START-BACKUP.bat directly on Windows.
