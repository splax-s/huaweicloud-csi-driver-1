# test.ps1 - run the EVS CSI validation suite with the settings install.ps1 recorded in kube-system/evs-csi-install.
#   ./test.ps1 [-Phases 1,2,3] [-XfsType <volume type>] [-Kubectl kubectl]
# Phases 4-7 create and delete real EVS disks (about 35 minutes for all 8 phases). Results go to results-<time>/.
param([string]$Phases = '1,2,3,4,5,6,7,8', [string]$XfsType = '', [int]$LoadPerAz = 10, [string]$Kubectl = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Kubectl) { $Kubectl = if (Get-Command oc -ErrorAction SilentlyContinue) { 'oc' } else { 'kubectl' } }
$cm = (& $Kubectl -n kube-system get configmap evs-csi-install -o json | ConvertFrom-Json).data
if (-not $cm) { throw 'kube-system/evs-csi-install not found: install with install.ps1 first' }
if (-not $cm.storageclasses) { throw 'install.ps1 was run without -VolumeTypes: no StorageClasses to test' }
if (-not $XfsType) { $XfsType = ((($cm.'volume-types' -split ',')[0]) -split '=')[1].Trim() }
$iam = ([Uri]$cm.'auth-url').Host
$out = Join-Path $here ('results-' + (Get-Date -Format 'yyyyMMdd-HHmm')); New-Item -ItemType Directory -Force $out | Out-Null
$ps = (Get-Process -Id $PID).Path
Write-Host "suite: $($cm.cloud) $($cm.region), classes $($cm.storageclasses), image $($cm.image), phases $Phases"
$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $here 'test/evs-suite.ps1'),
  '-Region', $cm.region, '-Cloud', $cm.cloud, '-ProjectId', $cm.'project-id', '-StorageClasses', $cm.storageclasses,
  '-XfsType', $XfsType, '-IamHost', $iam, '-Oc', (Get-Command $Kubectl).Source, '-Phases', $Phases,
  '-LoadPerAz', $LoadPerAz, '-Results', (Join-Path $out 'suite-results.jsonl'))
if ($cm.'gateway-ip') { $a += @('-GatewayIp', $cm.'gateway-ip') }
$ErrorActionPreference = 'Continue'   # the suite's stderr must not end the run
& $ps @a | Tee-Object -FilePath (Join-Path $out 'suite.log')
$r = Get-Content (Join-Path $out 'suite.log')
$sum = @(($r | Select-String 'Suite totals').Line, '', 'Not passing:') + @($r | Select-String '^(WARN|FAIL) ' | ForEach-Object { $_.Line })
$sum | Set-Content (Join-Path $out 'summary.txt'); $sum | Write-Host
Write-Host "results in $out"
