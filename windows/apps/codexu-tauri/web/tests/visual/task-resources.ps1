param([Parameter(Mandatory=$true)][int]$RootProcessId)
$ErrorActionPreference = 'Stop'
if ($RootProcessId -le 0) { throw 'invalid_root' }
# Read only PID/parent/birth/name for relationship discovery. No command line,
# executable path, environment, socket address, or unrelated process is emitted.
$all = @(Get-CimInstance Win32_Process -Property ProcessId,ParentProcessId,CreationDate,Name)
$root = @($all | Where-Object { $_.ProcessId -eq $RootProcessId })
if ($root.Count -ne 1 -or $root[0].Name -ne 'node.exe') { throw 'runner_not_found' }
$born = $root[0].CreationDate
$byId = @{}
foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
$owned = [Collections.Generic.HashSet[int]]::new()
[void]$owned.Add($RootProcessId)
for ($depth=0; $depth -lt 32; $depth++) {
  $added = 0
  foreach ($p in $all) {
    $parent = $byId[[int]$p.ParentProcessId]
    if ($null -ne $parent -and $p.CreationDate -ge $born -and $p.CreationDate -ge $parent.CreationDate -and $owned.Contains([int]$p.ParentProcessId) -and $owned.Add([int]$p.ProcessId)) { $added++ }
  }
  if ($added -eq 0) { break }
}
$rows = @()
foreach ($p in $all) {
  if (!$owned.Contains([int]$p.ProcessId)) { continue }
  try {
    $live = Get-Process -Id $p.ProcessId -ErrorAction Stop
    if ([Math]::Abs(($live.StartTime.ToUniversalTime() - $p.CreationDate.ToUniversalTime()).TotalSeconds) -gt 1) { continue }
    $kind = if ($p.Name -eq 'node.exe') { 'node' } elseif ($p.Name -in @('chrome.exe','msedge.exe','headless_shell.exe','chrome-headless-shell.exe')) { 'chromium' } else { 'task-child' }
    $rows += [pscustomobject]@{ pid=[int]$p.ProcessId; kind=$kind; workingSetBytes=$live.WorkingSet64; privateBytes=$live.PrivateMemorySize64; handles=$live.HandleCount; threads=$live.Threads.Count }
  } catch { }
}
$tcp = $null; $udp = $null; $socketStatus = 'unavailable'
try {
  $connections = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $owned.Contains([int]$_.OwningProcess) })
  $tcp = @($connections | Group-Object State | ForEach-Object { [pscustomobject]@{ state=[string]$_.Name; count=$_.Count } })
  $udp = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object { $owned.Contains([int]$_.OwningProcess) }).Count
  $socketStatus = 'captured'
} catch { }
[pscustomobject]@{ rootPid=$RootProcessId; processCount=$rows.Count; processes=$rows; tcpStates=$tcp; udpCount=$udp; socketStatus=$socketStatus; boundary='live task descendants only; exited processes and unowned TIME_WAIT are not attributed' } | ConvertTo-Json -Depth 6 -Compress
