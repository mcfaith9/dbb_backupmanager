#requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$Root=Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath=Join-Path $Root 'config\backup-jobs.json';$Worker=Join-Path $Root 'workers\BackupWorker.ps1'
$LogDir=Join-Path $Root 'logs';$StateDir=Join-Path $Root 'state'
New-Item -ItemType Directory -Force -Path $LogDir,$StateDir|Out-Null
$script:mutex=New-Object System.Threading.Mutex($false,'Local\NetworkBackupManagerStandalone')
if(!$script:mutex.WaitOne(0,$false)){[System.Windows.Forms.MessageBox]::Show('The manager is already running.');exit}
$cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
$script:jobs=@($cfg.jobs|Where-Object {$_.enabled -ne $false});$script:active=@{};$script:stopping=$false
$script:runLog=Join-Path $LogDir ('Manager-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log')
function StatePath($j){Join-Path $StateDir ($j.id+'.json')}
function ReadState($j){$p=StatePath $j;if(Test-Path $p){try{return Get-Content -LiteralPath $p -Raw|ConvertFrom-Json}catch{}};return $null}
function SaveState($j,$status,$message){$v=[ordered]@{jobId=$j.id;status=$status;message=$message;progress=0;exitCode=-1;attempt=0;updated=(Get-Date).ToString('o')};$v|ConvertTo-Json|Set-Content -LiteralPath (StatePath $j) -Encoding UTF8}
function Log($m){Add-Content -LiteralPath $script:runLog -Value ('[{0}] {1}' -f (Get-Date -Format 's'),$m) -Encoding UTF8}
# Recover jobs left active by a prior app/PC shutdown.
foreach($j in $script:jobs){$old=ReadState $j;if($old -and $old.status -in @('RUNNING','RETRYING','CHECKING CONNECTION')){SaveState $j 'STOPPED' 'Previous manager session ended; safe to resume with Robocopy /Z'}}
function LaunchJob($j){
  $jobLog=Join-Path $LogDir ($j.id+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.log');$state=StatePath $j
  $title="BACKUP - $($j.computer) - $($j.name)"
  $pa="-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$Worker`" -JobId `"$($j.id)`" -ConfigPath `"$ConfigPath`" -StatePath `"$state`" -LogPath `"$jobLog`""
  $cmd="title $title & color 0A & echo $title & powershell.exe $pa & echo. & echo Worker finished. Close this window when reviewed. & pause"
  $p=Start-Process -FilePath $env:ComSpec -ArgumentList @('/k',$cmd) -PassThru
  $script:active[$j.id]=[pscustomobject]@{Process=$p;Job=$j};SaveState $j 'CHECKING CONNECTION' 'Worker launched';Log "Started $($j.id), PID $($p.Id)"
}
function RefreshUI{
  $grid.Rows.Clear();$all=@()
  foreach($j in $script:jobs){$s=ReadState $j;$all+=,$s;$status=if($s){$s.status}else{'WAITING'};$prog=if($s){"$($s.progress)%"}else{'0%'};$attempt=if($s){$s.attempt}else{0};$rc=if($s){$s.exitCode}else{'-'};[void]$grid.Rows.Add($j.computer,$j.name,$j.source,$j.destination,$status,$prog,$attempt,$rc)}
  $done=@($all|Where-Object {$_.status -eq 'COMPLETED'}).Count;$failed=@($all|Where-Object {$_.status -eq 'FAILED'}).Count;$offline=@($all|Where-Object {$_.status -eq 'OFFLINE'}).Count;$running=@($all|Where-Object {$_.status -in @('RUNNING','RETRYING','CHECKING CONNECTION')}).Count
  $stats.Text="TOTAL $($script:jobs.Count)   RUNNING $running   COMPLETED $done   FAILED $failed   OFFLINE $offline"
  $bar.Value=if($script:jobs.Count){[Math]::Min(100,[int](100*$done/$script:jobs.Count))}else{0}
}
function StartQueue([bool]$freshRun=$false){
  $script:stopping=$false
  if($freshRun){Log 'New backup run started.'}else{Log 'Backup queue resumed.'}
  foreach($j in $script:jobs){if($script:active.ContainsKey($j.id)){continue};$s=ReadState $j;if($s -and $s.status -eq 'COMPLETED' -and -not $freshRun){continue};if($s -and $s.status -in @('RUNNING','RETRYING','CHECKING CONNECTION')){continue};SaveState $j 'WAITING' 'Queued'}
  $timer.Start()
}
function StopQueue{
  $script:stopping=$true;$timer.Stop()
  foreach($id in @($script:active.Keys)){$e=$script:active[$id];SaveState $e.Job 'STOPPED' 'Stopped by user; restartable transfer can resume';try{& taskkill.exe /PID $e.Process.Id /T /F|Out-Null}catch{};Log "Stopped $id process tree PID $($e.Process.Id)";$script:active.Remove($id)}
  RefreshUI
}
function TickQueue{
  foreach($id in @($script:active.Keys)){$e=$script:active[$id];$s=ReadState $e.Job;if($s -and $s.status -in @('COMPLETED','FAILED','OFFLINE')){$script:active.Remove($id)}elseif($e.Process.HasExited){if(!$s -or $s.status -notin @('COMPLETED','FAILED','OFFLINE')){SaveState $e.Job 'FAILED' 'Worker exited unexpectedly'};$script:active.Remove($id)}}
  if(!$script:stopping){$limit=[int]$concurrency.Value;foreach($j in $script:jobs){if($script:active.Count -ge $limit){break};if($script:active.ContainsKey($j.id)){continue};$s=ReadState $j;if($s -and $s.status -eq 'COMPLETED'){continue};if($s -and $s.status -in @('RUNNING','RETRYING','CHECKING CONNECTION')){continue};LaunchJob $j};$left=@($script:jobs|Where-Object {$s=ReadState $_;!($s -and $s.status -eq 'COMPLETED')}).Count;if($left -eq 0 -and $script:active.Count -eq 0){$timer.Stop()}}
  RefreshUI
}
$form=New-Object System.Windows.Forms.Form;$form.Text='Network Backup Manager';$form.Size=New-Object System.Drawing.Size(1360,760);$form.MinimumSize=New-Object System.Drawing.Size(1100,620);$form.StartPosition='CenterScreen';$form.BackColor=[System.Drawing.Color]::FromArgb(246,248,250);$form.Font=New-Object System.Drawing.Font('Segoe UI',9)
$heading=New-Object System.Windows.Forms.Label;$heading.Text='NETWORK BACKUP MANAGER';$heading.Font=New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold);$heading.Location='20,15';$heading.Size='600,35';$form.Controls.Add($heading)
$stats=New-Object System.Windows.Forms.Label;$stats.Text='TOTAL 0   RUNNING 0   COMPLETED 0   FAILED 0   OFFLINE 0';$stats.Location='22,55';$stats.Size='1000,25';$stats.Font=New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold);$form.Controls.Add($stats)
$bar=New-Object System.Windows.Forms.ProgressBar;$bar.Location='22,85';$bar.Size='1300,16';$form.Controls.Add($bar)
function AddButton($text,$x,$w){$b=New-Object System.Windows.Forms.Button;$b.Text=$text;$b.Location=New-Object System.Drawing.Point($x,115);$b.Size=New-Object System.Drawing.Size($w,38);$form.Controls.Add($b);return $b}
$start=AddButton 'START BACKUP' 22 140;$stop=AddButton 'STOP BACKUP' 172 140;$resume=AddButton 'RESUME BACKUP' 322 150;$logs=AddButton 'VIEW LOGS' 482 115;$open=AddButton 'OPEN BACKUP LOCATION' 607 190
$cl=New-Object System.Windows.Forms.Label;$cl.Text='Max concurrent jobs:';$cl.Location='835,124';$cl.Size='145,25';$form.Controls.Add($cl)
$concurrency=New-Object System.Windows.Forms.NumericUpDown;$concurrency.Location='985,121';$concurrency.Size='60,25';$concurrency.Minimum=1;$concurrency.Maximum=12;$concurrency.Value=[Math]::Max(1,[Math]::Min(12,[int]$cfg.settings.maxConcurrentJobs));$form.Controls.Add($concurrency)
$grid=New-Object System.Windows.Forms.DataGridView;$grid.Location='22,170';$grid.Size='1300,510';$grid.Anchor='Top,Bottom,Left,Right';$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.ReadOnly=$true;$grid.RowHeadersVisible=$false;$grid.SelectionMode='FullRowSelect';$grid.AutoSizeColumnsMode='DisplayedCells';$grid.BackgroundColor=[System.Drawing.Color]::White
@('COMPUTER','BACKUP JOB','SOURCE PATH','DESTINATION PATH','STATUS','PROGRESS','ATTEMPT','EXIT CODE')|ForEach-Object{[void]$grid.Columns.Add($_,$_) };$grid.Columns[0].Width=90;$grid.Columns[1].Width=145;$grid.Columns[2].Width=300;$grid.Columns[3].Width=300;$grid.Columns[4].Width=135;$form.Controls.Add($grid)
$foot=New-Object System.Windows.Forms.Label;$foot.Text="Portable Windows app | Robocopy /Z | No /MIR or /PURGE | Logs: $LogDir";$foot.Location='22,690';$foot.Size='1200,22';$foot.Anchor='Bottom,Left';$form.Controls.Add($foot)
$timer=New-Object System.Windows.Forms.Timer;$timer.Interval=1000;$timer.Add_Tick({TickQueue});$start.Add_Click({StartQueue $true});$resume.Add_Click({StartQueue $false});$stop.Add_Click({StopQueue});$logs.Add_Click({Start-Process explorer.exe -ArgumentList "`"$LogDir`""})
$open.Add_Click({if($grid.SelectedRows.Count){$i=$grid.SelectedRows[0].Index;$d=$script:jobs[$i].destination;if(Test-Path -LiteralPath $d){Start-Process explorer.exe -ArgumentList "`"$d`""}else{[System.Windows.Forms.MessageBox]::Show("Destination not created yet:`r`n$d")|Out-Null}}else{Start-Process explorer.exe -ArgumentList 'D:\'}})
$form.Add_Shown({RefreshUI})
$form.Add_FormClosing({if($script:active.Count -gt 0){$a=[System.Windows.Forms.MessageBox]::Show('Backup jobs are running. Stop them before closing?','Confirm Exit','YesNoCancel','Warning');if($a -eq 'Cancel'){$_.Cancel=$true;return};if($a -eq 'Yes'){StopQueue};if($a -eq 'No'){$_.Cancel=$true;return}};try{$script:mutex.ReleaseMutex();$script:mutex.Dispose()}catch{}})
[void]$form.ShowDialog()
