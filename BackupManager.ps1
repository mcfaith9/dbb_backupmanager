#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'config\backup-jobs.json'
$Worker = Join-Path $Root 'workers\BackupWorker.ps1'
$LogDir = Join-Path $Root 'logs'
$StateDir = Join-Path $Root 'state'
$CredentialDir = Join-Path $Root 'credentials'
New-Item -ItemType Directory -Force -Path $LogDir, $StateDir, $CredentialDir | Out-Null

if (!(Test-Path -LiteralPath $ConfigPath)) { [System.Windows.Forms.MessageBox]::Show("Configuration file not found:`r`n$ConfigPath", 'Backup Manager', 'OK', 'Error') | Out-Null; exit 1 }
if (!(Test-Path -LiteralPath $Worker)) { [System.Windows.Forms.MessageBox]::Show("Worker file not found:`r`n$Worker", 'Backup Manager', 'OK', 'Error') | Out-Null; exit 1 }

$script:mutex = New-Object System.Threading.Mutex($false, 'Local\NetworkBackupManagerStandalone')
if (!$script:mutex.WaitOne(0, $false)) { [System.Windows.Forms.MessageBox]::Show('The manager is already running.') | Out-Null; exit }

try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
catch { [System.Windows.Forms.MessageBox]::Show("Invalid backup-jobs.json:`r`n$($_.Exception.Message)", 'Backup Manager', 'OK', 'Error') | Out-Null; exit 1 }

# Provision supplied profile passwords into Windows DPAPI-protected credential files.
# Plaintext passwords remain in the local JSON because automatic setup was requested.
foreach ($profile in @($cfg.credentialProfiles)) {
    if (![string]::IsNullOrWhiteSpace([string]$profile.password) -and ![string]::IsNullOrWhiteSpace([string]$profile.host) -and ![string]::IsNullOrWhiteSpace([string]$profile.username)) {
        $credentialFile = Join-Path $CredentialDir ([string]$profile.host + '.credential.xml')
        if (!(Test-Path -LiteralPath $credentialFile)) {
            try {
                $securePassword = ConvertTo-SecureString ([string]$profile.password) -AsPlainText -Force
                $savedCredential = New-Object System.Management.Automation.PSCredential([string]$profile.username, $securePassword)
                $savedCredential | Export-Clixml -LiteralPath $credentialFile -Force
                $securePassword = $null
                $savedCredential = $null
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Could not initialize credentials for $($profile.computer):`r`n$($_.Exception.Message)", 'Credential Setup Warning', 'OK', 'Warning') | Out-Null
            }
        }
    }
}

$script:allJobs = @($cfg.jobs | Where-Object { $_.enabled -ne $false })
$script:jobs = @()
$script:active = $null
$script:queue = @()
$script:stopping = $false
$script:runLog = Join-Path $LogDir ('Manager-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

function StatePath($job) { Join-Path $StateDir ($job.id + '.json') }
function ReadState($job) {
    $path = StatePath $job
    if (Test-Path -LiteralPath $path) { try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch {} }
    return $null
}
function SaveState($job, $status, $message) {
    $state = [ordered]@{ jobId=$job.id; status=$status; message=$message; progress=0; exitCode=-1; attempt=0; updated=(Get-Date).ToString('o') }
    $state | ConvertTo-Json | Set-Content -LiteralPath (StatePath $job) -Encoding UTF8
}
function Log($message) { Add-Content -LiteralPath $script:runLog -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $message) -Encoding UTF8 }

# Mark jobs left active by an earlier manager session as resumable.
foreach ($job in $script:allJobs) {
    $old = ReadState $job
    if ($old -and $old.status -in @('RUNNING','RETRYING','CHECKING CONNECTION')) { SaveState $job 'STOPPED' 'Previous manager session ended; safe to resume with Robocopy /Z' }
}

function UpdateFolderChoices {
    $folderList.Items.Clear()
    $computer = [string]$computerList.SelectedItem
    if (!$computer) { return }
    $pcJobs = @($script:allJobs | Where-Object { $_.computer -eq $computer })
    foreach ($job in $pcJobs) { [void]$folderList.Items.Add($job.name, $false) }
    $selectionHint.Text = "$computer - select only the folders you want to back up."
}
function GetSelectedJobs {
    $computer = [string]$computerList.SelectedItem
    if (!$computer) { return @() }
    $names = @()
    foreach ($item in $folderList.CheckedItems) { $names += [string]$item }
    return @($script:allJobs | Where-Object { $_.computer -eq $computer -and $names -contains $_.name })
}
function RefreshUI {
    $grid.Rows.Clear()
    $allStates = @()
    foreach ($job in $script:jobs) {
        $state = ReadState $job
        if ($state) { $allStates += ,$state }
        $status = if ($state) { $state.status } else { 'WAITING' }
        $progress = if ($state) { "$($state.progress)%" } else { '0%' }
        $attempt = if ($state) { $state.attempt } else { 0 }
        $exitCode = if ($state) { $state.exitCode } else { '-' }
        [void]$grid.Rows.Add($job.computer, $job.name, $job.source, $job.destination, $status, $progress, $attempt, $exitCode)
    }
    $done = @($allStates | Where-Object { $_.status -eq 'COMPLETED' }).Count
    $failed = @($allStates | Where-Object { $_.status -eq 'FAILED' }).Count
    $offline = @($allStates | Where-Object { $_.status -eq 'OFFLINE' }).Count
    $running = @($allStates | Where-Object { $_.status -in @('RUNNING','RETRYING','CHECKING CONNECTION') }).Count
    $stats.Text = "SELECTED $($script:jobs.Count)    RUNNING $running    COMPLETED $done    FAILED $failed    OFFLINE $offline"
    $bar.Value = if ($script:jobs.Count) { [Math]::Min(100, [int](100 * $done / $script:jobs.Count)) } else { 0 }
}
function LaunchNextJob {
    if ($script:stopping -or $script:active -or $script:queue.Count -eq 0) { return }
    $job = $script:queue[0]
    if ($script:queue.Count -gt 1) { $script:queue = @($script:queue | Select-Object -Skip 1) } else { $script:queue = @() }
    $jobLog = Join-Path $LogDir ($job.id + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    $credentialPath = Join-Path $CredentialDir ($job.host + '.credential.xml')
    $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Worker,'-JobId',$job.id,'-ConfigPath',$ConfigPath,'-StatePath',(StatePath $job),'-LogPath',$jobLog,'-CredentialPath',$credentialPath)
    $argumentLine = ($arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' }) -join ' '
    try {
        SaveState $job 'CHECKING CONNECTION' 'Starting background worker'
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
        $script:active = [pscustomobject]@{ Process=$process; Job=$job }
        Log "Started $($job.id) ($($job.computer) / $($job.name)); PID $($process.Id)"
    } catch {
        SaveState $job 'FAILED' ("Could not start worker: " + $_.Exception.Message)
        Log "Failed to start $($job.id): $($_.Exception.Message)"
        LaunchNextJob
    }
}
function StartQueue([bool]$freshRun = $false) {
    if ($script:active) { [System.Windows.Forms.MessageBox]::Show('A backup is already running. Stop it before starting another selection.') | Out-Null; return }
    $chosen = @(GetSelectedJobs)
    if (!$chosen -or $chosen.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select a computer and at least one folder first.', 'No folders selected', 'OK', 'Information') | Out-Null; return }
    $script:jobs = $chosen
    foreach ($selectedJob in $chosen) {
        $credPath = Join-Path $CredentialDir ($selectedJob.host + '.credential.xml')
        if (!(Test-Path -LiteralPath $credPath)) {
            [System.Windows.Forms.MessageBox]::Show("Network credentials are missing for $($selectedJob.computer) ($($selectedJob.host)).`r`nClick NETWORK CREDENTIALS, enter the password, and save it before starting the backup.",'Credentials Required','OK','Warning') | Out-Null
            $computerList.SelectedItem = $selectedJob.computer
            ShowCredentialDialog
            if (!(Test-Path -LiteralPath $credPath)) { return }
        }
    }
    $script:stopping = $false
    if ($freshRun) {
        foreach ($job in $script:jobs) { SaveState $job 'WAITING' 'Queued in a new selected backup run' }
        $script:queue = @($script:jobs)
        Log 'New selected backup run started.'
    } else {
        $script:queue = @($script:jobs | Where-Object { $state = ReadState $_; !($state -and $state.status -eq 'COMPLETED') })
        Log 'Selected backup queue resumed; completed folders will be skipped.'
    }
    if ($script:queue.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('All selected folders are already completed. Choose Start Selected Backup to run them again.') | Out-Null; RefreshUI; return }
    $timer.Start()
    LaunchNextJob
    RefreshUI
}
function StopQueue {
    $script:stopping = $true
    $script:queue = @()
    $timer.Stop()
    if ($script:active) {
        $entry = $script:active
        SaveState $entry.Job 'STOPPED' 'Stopped by user; Robocopy /Z allows restartable transfer'
        try { & taskkill.exe /PID $entry.Process.Id /T /F 2>&1 | Out-Null } catch {}
        Log "Stopped $($entry.Job.id), process tree PID $($entry.Process.Id)"
        $script:active = $null
    }
    RefreshUI
}
function TickQueue {
    if ($script:active) {
        $entry = $script:active
        if ($entry.Process.HasExited) {
            $state = ReadState $entry.Job
            if ($state -and $state.status -in @('COMPLETED','FAILED','OFFLINE')) {
                Log "$($entry.Job.id) finished with status $($state.status)"
            } else {
                SaveState $entry.Job 'FAILED' 'Worker exited unexpectedly; check its log'
                Log "$($entry.Job.id) worker exited unexpectedly"
            }
            $script:active = $null
        }
    }
    if (!$script:stopping) {
        if (!$script:active -and $script:queue.Count -gt 0) { LaunchNextJob }
        if ($script:queue.Count -eq 0 -and !$script:active) { $timer.Stop(); Log 'Selected backup queue completed.' }
    }
    RefreshUI
}


function Get-CredentialProfile($computer) {
    $profiles = @($cfg.credentialProfiles)
    return $profiles | Where-Object { $_.computer -eq $computer } | Select-Object -First 1
}
function Test-CredentialSaved($hostName) {
    $path = Join-Path $CredentialDir ($hostName + '.credential.xml')
    return (Test-Path -LiteralPath $path)
}
function ShowCredentialDialog {
    $computer = [string]$computerList.SelectedItem
    if ([string]::IsNullOrWhiteSpace($computer)) { return }
    $profile = Get-CredentialProfile $computer
    if (!$profile) { [System.Windows.Forms.MessageBox]::Show('No credential profile is configured for this computer.','Network Credentials','OK','Information') | Out-Null; return }
    $hostName = [string]$profile.host
    $path = Join-Path $CredentialDir ($hostName + '.credential.xml')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Network Credentials - $computer"
    $dlg.Size = New-Object System.Drawing.Size(500,260)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI',9)
    $lblHost = New-Object System.Windows.Forms.Label; $lblHost.Text = "Computer: $computer    IP: $hostName"; $lblHost.Location='18,18'; $lblHost.Size='440,24'; $dlg.Controls.Add($lblHost)
    $lblUser = New-Object System.Windows.Forms.Label; $lblUser.Text='Windows username'; $lblUser.Location='18,55'; $lblUser.Size='150,22'; $dlg.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox; $txtUser.Location='175,52'; $txtUser.Size='285,25'; $txtUser.Text=[string]$profile.username; $dlg.Controls.Add($txtUser)
    $lblPass = New-Object System.Windows.Forms.Label; $lblPass.Text='Windows password'; $lblPass.Location='18,91'; $lblPass.Size='150,22'; $dlg.Controls.Add($lblPass)
    $txtPass = New-Object System.Windows.Forms.TextBox; $txtPass.Location='175,88'; $txtPass.Size='285,25'; $txtPass.UseSystemPasswordChar=$true; $dlg.Controls.Add($txtPass)
    $note = New-Object System.Windows.Forms.Label; $note.Text='Password is encrypted for this Windows user. It is never written to JSON or logs.'; $note.Location='18,124'; $note.Size='445,38'; $note.ForeColor=[System.Drawing.Color]::DimGray; $dlg.Controls.Add($note)
    $save = New-Object System.Windows.Forms.Button; $save.Text='Save Securely'; $save.Location='255,172'; $save.Size='105,32'; $dlg.Controls.Add($save)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text='Cancel'; $cancel.Location='370,172'; $cancel.Size='90,32'; $cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $dlg.Controls.Add($cancel)
    $dlg.AcceptButton=$save; $dlg.CancelButton=$cancel
    $save.Add_Click({
        if ([string]::IsNullOrWhiteSpace($txtUser.Text) -or [string]::IsNullOrEmpty($txtPass.Text)) { [System.Windows.Forms.MessageBox]::Show('Enter both username and password.','Missing credentials','OK','Warning') | Out-Null; return }
        try {
            $secure = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($txtUser.Text,$secure)
            $credential | Export-Clixml -LiteralPath $path -Force
            $txtPass.Clear()
            $dlg.DialogResult=[System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        } catch { [System.Windows.Forms.MessageBox]::Show("Could not save encrypted credentials:`r`n$($_.Exception.Message)",'Credential Error','OK','Error') | Out-Null }
    })
    [void]$dlg.ShowDialog($form)
    UpdateCredentialStatus
}
function UpdateCredentialStatus {
    $computer = [string]$computerList.SelectedItem
    if (!$computer -or !$credentialStatus) { return }
    $profile = Get-CredentialProfile $computer
    if (!$profile) { $credentialStatus.Text='No credential profile'; return }
    $saved = Test-CredentialSaved ([string]$profile.host)
    $credentialStatus.Text = if ($saved) { "Credentials saved for $($profile.host)" } else { "Credentials not saved for $($profile.host)" }
    $credentialStatus.ForeColor = if ($saved) { [System.Drawing.Color]::ForestGreen } else { [System.Drawing.Color]::Firebrick }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Network Backup Manager'
$form.Size = New-Object System.Drawing.Size(1380, 800)
$form.MinimumSize = New-Object System.Drawing.Size(1120, 700)
$form.StartPosition = 'CenterScreen'
$form.BackColor = [System.Drawing.Color]::FromArgb(246,248,250)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$heading = New-Object System.Windows.Forms.Label; $heading.Text = 'NETWORK BACKUP MANAGER'; $heading.Font = New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold); $heading.Location = '20,14'; $heading.Size = '600,34'; $form.Controls.Add($heading)
$stats = New-Object System.Windows.Forms.Label; $stats.Text = 'SELECTED 0    RUNNING 0    COMPLETED 0    FAILED 0    OFFLINE 0'; $stats.Location = '22,50'; $stats.Size = '1100,24'; $stats.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold); $form.Controls.Add($stats)
$bar = New-Object System.Windows.Forms.ProgressBar; $bar.Location = '22,78'; $bar.Size = '1320,15'; $form.Controls.Add($bar)

$selectTitle = New-Object System.Windows.Forms.Label; $selectTitle.Text = '1. SELECT COMPUTER'; $selectTitle.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold); $selectTitle.Location = '22,108'; $selectTitle.Size = '250,22'; $form.Controls.Add($selectTitle)
$computerList = New-Object System.Windows.Forms.ComboBox; $computerList.Location = '22,134'; $computerList.Size = '250,30'; $computerList.DropDownStyle = 'DropDownList'; $computerNames = @(@($script:allJobs | Select-Object -ExpandProperty computer) + @($cfg.credentialProfiles | Select-Object -ExpandProperty computer) | Sort-Object -Unique); $computerList.Items.AddRange([string[]]$computerNames); $form.Controls.Add($computerList)
$folderTitle = New-Object System.Windows.Forms.Label; $folderTitle.Text = '2. SELECT FOLDERS TO BACK UP'; $folderTitle.Font = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold); $folderTitle.Location = '300,108'; $folderTitle.Size = '320,22'; $form.Controls.Add($folderTitle)
$folderList = New-Object System.Windows.Forms.CheckedListBox; $folderList.Location = '300,134'; $folderList.Size = '360,116'; $folderList.CheckOnClick = $true; $folderList.BorderStyle = 'FixedSingle'; $form.Controls.Add($folderList)
$selectionHint = New-Object System.Windows.Forms.Label; $selectionHint.Text = 'Choose a computer to view its available folders.'; $selectionHint.Location = '680,137'; $selectionHint.Size = '640,25'; $form.Controls.Add($selectionHint)
$credentialStatus = New-Object System.Windows.Forms.Label; $credentialStatus.Text = 'Select a computer to view credential status.'; $credentialStatus.Location = '680,205'; $credentialStatus.Size = '450,24'; $form.Controls.Add($credentialStatus)
$credentialButton = New-Object System.Windows.Forms.Button; $credentialButton.Text = 'NETWORK CREDENTIALS'; $credentialButton.Location = '1140,170'; $credentialButton.Size = '190,32'; $form.Controls.Add($credentialButton)
$selectAll = New-Object System.Windows.Forms.Button; $selectAll.Text = 'Select All'; $selectAll.Location = '680,170'; $selectAll.Size = '100,30'; $form.Controls.Add($selectAll)
$clearAll = New-Object System.Windows.Forms.Button; $clearAll.Text = 'Clear'; $clearAll.Location = '790,170'; $clearAll.Size = '90,30'; $form.Controls.Add($clearAll)

function AddButton($text, $x, $width) { $button = New-Object System.Windows.Forms.Button; $button.Text = $text; $button.Location = New-Object System.Drawing.Point($x,270); $button.Size = New-Object System.Drawing.Size($width,38); $form.Controls.Add($button); return $button }
$start = AddButton 'START SELECTED BACKUP' 22 190
$stop = AddButton 'STOP BACKUP' 222 140
$resume = AddButton 'RESUME SELECTED' 372 170
$logs = AddButton 'VIEW LOGS' 552 115
$open = AddButton 'OPEN BACKUP LOCATION' 677 190

$grid = New-Object System.Windows.Forms.DataGridView; $grid.Location = '22,325'; $grid.Size = '1320,380'; $grid.Anchor = 'Top,Bottom,Left,Right'; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.ReadOnly = $true; $grid.RowHeadersVisible = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.AutoSizeColumnsMode = 'DisplayedCells'; $grid.BackgroundColor = [System.Drawing.Color]::White
@('COMPUTER','BACKUP FOLDER','SOURCE PATH','DESTINATION PATH','STATUS','PROGRESS','ATTEMPT','EXIT CODE') | ForEach-Object { [void]$grid.Columns.Add($_,$_) }
$grid.Columns[0].Width = 90; $grid.Columns[1].Width = 160; $grid.Columns[2].Width = 330; $grid.Columns[3].Width = 330; $grid.Columns[4].Width = 145
$form.Controls.Add($grid)
$foot = New-Object System.Windows.Forms.Label; $foot.Text = "One background worker at a time | Robocopy /Z | No /MIR or /PURGE | Logs: $LogDir"; $foot.Location = '22,715'; $foot.Size = '1250,22'; $foot.Anchor = 'Bottom,Left'; $form.Controls.Add($foot)

$timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 1000; $timer.Add_Tick({ TickQueue })
$computerList.Add_SelectedIndexChanged({ UpdateFolderChoices; UpdateCredentialStatus })
$credentialButton.Add_Click({ ShowCredentialDialog })
$selectAll.Add_Click({ for ($i=0; $i -lt $folderList.Items.Count; $i++) { $folderList.SetItemChecked($i,$true) } })
$clearAll.Add_Click({ for ($i=0; $i -lt $folderList.Items.Count; $i++) { $folderList.SetItemChecked($i,$false) } })
$start.Add_Click({ StartQueue $true })
$resume.Add_Click({ StartQueue $false })
$stop.Add_Click({ StopQueue })
$logs.Add_Click({ Start-Process explorer.exe -ArgumentList ('"' + $LogDir + '"') })
$open.Add_Click({
    if ($grid.SelectedRows.Count -gt 0) {
        $row = $grid.SelectedRows[0].Index
        if ($row -ge 0 -and $row -lt $script:jobs.Count) {
            $dest = [string]$script:jobs[$row].destination
            if (Test-Path -LiteralPath $dest) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList @($dest)
            }
            else {
                [System.Windows.Forms.MessageBox]::Show(("Destination not created yet:`r`n{0}" -f $dest)) | Out-Null
            }
        }
    }
    else {
        Start-Process -FilePath 'explorer.exe' -ArgumentList @('D:\')
    }
})
$form.Add_Shown({ if ($computerList.Items.Count -gt 0) { $computerList.SelectedIndex = 0 }; RefreshUI })
$form.Add_FormClosing({
    if ($script:active) {
        $answer = [System.Windows.Forms.MessageBox]::Show('A backup is running. Stop it before closing?', 'Confirm Exit', 'YesNoCancel', 'Warning')
        if ($answer -eq 'Cancel' -or $answer -eq 'No') { $_.Cancel = $true; return }
        if ($answer -eq 'Yes') { StopQueue }
    }
    try { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() } catch {}
})
[void]$form.ShowDialog()
