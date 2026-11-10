NETWORK BACKUP MANAGER
======================

START
1. Extract the complete NetworkBackupManager folder on the backup PC.
2. Confirm drive D: is available.
3. Double-click START-BACKUP.bat.
4. Click START BACKUP. Default maximum concurrency is 3.

FEATURES
- Lightweight native Windows Forms GUI (PowerShell + .NET Framework).
- Separate green CMD window (color 0A) for each Robocopy job.
- Maximum concurrent jobs configurable in the GUI.
- SMB TCP port 445 connection check, 3 attempts, 10-second delay.
- Robocopy retries up to 3 job attempts after a Robocopy failure.
- Stop, Resume, persistent per-job state, and logs.
- Completed jobs are skipped when resuming.
- No /MIR or /PURGE; destination files are not automatically deleted.

REQUIREMENTS
- Windows 10/11 or Windows Server with Windows PowerShell 5.1.
- .NET Framework / Windows Forms available (included with supported Windows).
- Access to the remote SMB shares and write access to drive D:.
- TCP port 445 permitted between the backup PC and remote computers.

CONFIGURATION
Edit config\backup-jobs.json. Each job has a unique id, computer, name, host,
source, destination, and enabled flag. Settings control concurrency, SMB retries,
retry delay, job retries, and Robocopy thread count. Excluded extensions are
configured in robocopy.excludeFiles.

STOP / RESUME
STOP BACKUP stops scheduling and terminates only the CMD process trees started
by this manager. Already copied files remain. RESUME BACKUP retries incomplete,
failed, offline, and stopped jobs; completed jobs are skipped. Robocopy /Z is
used for restartable file transfers.

IMPORTANT NOTES
- Authenticate to remote shares using Windows credentials if prompted. The app
does not store passwords.
- A remote PC may be powered on but still fail the SMB check if file sharing or
its firewall blocks TCP 445.
- Each completed CMD window remains open so its final output can be reviewed;
close it manually when finished. It no longer counts against active concurrency.
- Robocopy does not provide a reliable overall percentage for every folder tree.
The GUI displays percentage output when Robocopy emits it; otherwise progress
may remain at 0% while files are being processed. The CMD window shows the real
Robocopy output.
- Test the configuration and permissions with a small subset of jobs first.
