param([string]$JobId,[string]$ConfigPath,[string]$StatePath,[string]$LogPath)
$ErrorActionPreference='Stop'
function Set-JobState([string]$status,[string]$message='',[int]$progress=0,[int]$exitCode=-1,[int]$attempt=0) {
  $o=[ordered]@{jobId=$JobId;status=$status;message=$message;progress=$progress;exitCode=$exitCode;attempt=$attempt;updated=(Get-Date).ToString('o')}
  $tmp="$StatePath.tmp"; $o|ConvertTo-Json|Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}
try {
  $cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
  $job=$cfg.jobs|Where-Object id -eq $JobId|Select-Object -First 1
  if(!$job){throw "Unknown job: $JobId"}
  Write-Host '============================================================'
  Write-Host "BACKUP: $($job.computer) - $($job.name)"
  Write-Host "SOURCE: $($job.source)"; Write-Host "DESTINATION: $($job.destination)"
  Write-Host '============================================================'
  Set-JobState 'CHECKING CONNECTION' 'Checking SMB TCP port 445'
  $online=$false; $tries=[int]$cfg.settings.connectionAttempts
  for($i=1;$i -le $tries;$i++) {
    Write-Host "SMB connection attempt $i/$tries to $($job.host):445"
    $c=New-Object Net.Sockets.TcpClient
    try { $a=$c.BeginConnect([string]$job.host,445,$null,$null); if($a.AsyncWaitHandle.WaitOne(2500,$false)){$c.EndConnect($a);$online=$true} } catch {$online=$false} finally {$c.Close()}
    if($online){break}
    if($i -lt $tries){Set-JobState 'RETRYING' "SMB attempt $i failed; waiting" 0 -1 $i; Start-Sleep -Seconds ([int]$cfg.settings.connectionRetryDelaySeconds)}
  }
  if(!$online){Write-Host 'OFFLINE after retry limit.';Set-JobState 'OFFLINE' 'SMB unavailable after retry limit' 0 -1 $tries;exit 20}
  if(!(Test-Path -LiteralPath $job.source)){throw "Source path unavailable or access denied: $($job.source)"}
  $drive=[IO.Path]::GetPathRoot([string]$job.destination)
  if(!(Test-Path -LiteralPath $drive)){throw "Destination drive unavailable: $drive"}
  New-Item -ItemType Directory -Force -Path $job.destination|Out-Null
  $base=@($cfg.robocopy.baseArguments)|Where-Object {$_ -notmatch '^/MT:'}
  $base+=('/MT:'+[int]$cfg.settings.robocopyThreads)
  $robocopyArgs=@($job.source,$job.destination)+$base+@('/XF')+@($cfg.robocopy.excludeFiles)
  $max=[int]$cfg.settings.jobRetryAttempts
  for($n=1;$n -le $max;$n++){
    Write-Host "`nROBOCOPY ATTEMPT $n/$max"
    Set-JobState 'RUNNING' "Robocopy attempt $n/$max" 0 -1 $n
    $progress=0
    & robocopy @robocopyArgs 2>&1 | ForEach-Object {
      $line=$_.ToString(); Write-Host $line; Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
      if($line -match '(\d{1,3})%'){$p=[Math]::Min(100,[int]$Matches[1]);if($p -ge $progress){$progress=$p;Set-JobState 'RUNNING' 'Copying' $progress -1 $n}}
    }
    $rc=$LASTEXITCODE; Write-Host "Robocopy exit code: $rc"
    if($rc -lt 8){Set-JobState 'COMPLETED' "Completed; Robocopy exit code $rc" 100 $rc $n;exit 0}
    if($n -lt $max){Set-JobState 'RETRYING' "Robocopy exit code $rc; retrying" $progress $rc $n;Start-Sleep -Seconds 10}
    else{Set-JobState 'FAILED' "Robocopy failed after $max attempts" $progress $rc $n;exit $rc}
  }
} catch {
  $msg=$_.Exception.Message; Write-Host "ERROR: $msg"; try{Add-Content -LiteralPath $LogPath -Value "ERROR: $msg" -Encoding UTF8}catch{}
  Set-JobState 'FAILED' $msg 0 -1 0; exit 99
}
