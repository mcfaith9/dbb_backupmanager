param([string]$JobId,[string]$ConfigPath,[string]$StatePath,[string]$LogPath,[string]$CredentialPath)
$ErrorActionPreference='Stop'
function Set-JobState([string]$status,[string]$message='',[int]$progress=0,[int]$exitCode=-1,[int]$attempt=0) {
  $o=[ordered]@{jobId=$JobId;status=$status;message=$message;progress=$progress;exitCode=$exitCode;attempt=$attempt;updated=(Get-Date).ToString('o')}
  $tmp="$StatePath.tmp"; $o|ConvertTo-Json|Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}
function Connect-SmbWithCredential([string]$hostName,[string]$credentialFile) {
  if (!(Test-Path -LiteralPath $credentialFile)) { throw "Encrypted Windows credentials are missing for $hostName. Open NETWORK CREDENTIALS in the manager and save them first." }
  $cred = Import-Clixml -LiteralPath $credentialFile
  if (!($cred -is [System.Management.Automation.PSCredential])) { throw "Credential file for $hostName is invalid. Re-save the credentials in the manager." }
  if (-not ([System.Management.Automation.PSTypeName]'NetworkBackup.WNet').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace NetworkBackup {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct NETRESOURCE { public int dwScope; public int dwType; public int dwDisplayType; public int dwUsage; public string lpLocalName; public string lpRemoteName; public string lpComment; public string lpProvider; }
  public static class WNet {
    [DllImport("mpr.dll", CharSet=CharSet.Unicode)] public static extern int WNetAddConnection2(ref NETRESOURCE netResource, string password, string username, int flags);
    [DllImport("mpr.dll", CharSet=CharSet.Unicode)] public static extern int WNetCancelConnection2(string name, int flags, bool force);
  }
}
"@
  }
  $resource = New-Object NetworkBackup.NETRESOURCE
  $resource.dwType = 1
  $resource.lpRemoteName = "\\$hostName\IPC$"
  $plain = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
  try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($plain); $result = [NetworkBackup.WNet]::WNetAddConnection2([ref]$resource,$password,$cred.UserName,0) }
  finally { if ($plain -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($plain) }; $password = $null }
  if ($result -ne 0 -and $result -ne 1219) {
    $message = (New-Object ComponentModel.Win32Exception($result)).Message
    throw "SMB authentication failed for $hostName as $($cred.UserName): $message (Windows error $result)"
  }
  if ($result -eq 1219) { throw "Windows already has an SMB connection to $hostName using different credentials (error 1219). Close existing connections to this PC using 'net use \\$hostName\* /delete' and try again." }
  return "Authenticated as $($cred.UserName)"
}
try {
  $cfg=Get-Content -LiteralPath $ConfigPath -Raw|ConvertFrom-Json
  $job=$cfg.jobs|Where-Object id -eq $JobId|Select-Object -First 1
  if(!$job){throw "Unknown job: $JobId"}
  Write-Host '============================================================'
  Write-Host "BACKUP: $($job.computer) - $($job.name)"
  Write-Host "SOURCE: $($job.source)"; Write-Host "DESTINATION: $($job.destination)"
  Write-Host '============================================================'
  Set-JobState 'CHECKING CONNECTION' 'Authenticating to remote SMB share'
  $authMessage = Connect-SmbWithCredential ([string]$job.host) $CredentialPath
  Write-Host $authMessage
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
  if(!(Test-Path -LiteralPath $job.source)){throw "Source path unavailable or access denied after SMB authentication: $($job.source). Verify the share name, remote folder permissions, and Windows username."}
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
