# install.ps1 - install the EVS CSI driver on OpenShift or Kubernetes, on Huawei Cloud Stack or Huawei Cloud.
#
#   ./install.ps1 -Cloud cloud.example.com -Region xx-xxxx-1 -ProjectId <project id> -CredentialsCsv ./credentials.csv `
#     -Hcs -VolumeTypes 'az1=<volume type>,az2=<volume type>' -Image <registry>/evs-csi-plugin@sha256:<digest> `
#     [-GatewayIp xx.xx.xx.xx] [-FetchCa <host or ip> [-CaFingerprint <sha256>] | -CaFile ./ca.crt | -Insecure]
#
# Writes the kube-system/cloud-config secret (keys are never printed), one StorageClass per AZ, the driver, and a
# kube-system/evs-csi-install ConfigMap with the non-secret settings that test.ps1 reads. Run it again to change
# settings; -Uninstall removes the driver (secret, StorageClasses, volumes and disks stay).
param(
  [Parameter(Mandatory)] [string]$Cloud,          # domain of the cloud, e.g. cloud.example.com or myhuaweicloud.com
  [Parameter(Mandatory)] [string]$Region,         # region, e.g. xx-xxxx-1
  [Parameter(Mandatory)] [string]$ProjectId,      # project (resource space) the disks are created in
  [string]$CredentialsCsv = '',                   # IAM user's credentials.csv (Access Key Id, Secret Access Key)
  [switch]$Hcs,                                   # Huawei Cloud Stack: hcs=true and skip-catalog=true
  [string]$AuthUrl = '',                          # default: https://iam-apigateway-proxy.<cloud>/v3 (HCS), https://iam.<cloud>/v3
  [string]$VolumeTypes = '',                      # 'az=volume-type,...': one StorageClass evs-<az> per AZ
  [string]$Fstype = 'ext4',
  [string]$Image = '',                            # driver image, best pinned by digest
  [string]$GatewayIp = '',                        # pin evs/ecs.<region>.<cloud> to this IP when DNS lacks them
  [string]$CaFile = '',                           # PEM CA bundle that signs the API certificates
  [string]$FetchCa = '',                          # host[:port] to read the CA chain from (checked against -CaFingerprint)
  [string]$CaFingerprint = '',                    # SHA-256 of the root CA, from your cloud operator
  [switch]$Insecure,                              # skip TLS verification (not for production)
  [double]$ApiRateLimit = -1,                     # API calls per second per plugin pod; default 0.5 with -Hcs, else off
  [int]$ApiBurst = 50,
  [switch]$KeepSecret,                            # leave the existing cloud-config secret as it is
  [switch]$Uninstall,
  [switch]$DryRun,                                # render everything to manifests/generated, change nothing
  [string]$Kubectl = ''                           # oc or kubectl; default: oc if found, else kubectl
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$KS = 'kube-system'
$gen = Join-Path $here 'manifests/generated'
New-Item -ItemType Directory -Force $gen | Out-Null
function Say($m) { Write-Host "$(Get-Date -Format 'HH:mm:ss') $m" }
function Stop-Install($m) { Write-Host "STOP: $m" -ForegroundColor Red; exit 1 }
function WriteLf($path, $text) { [IO.File]::WriteAllText($path, ($text -replace "`r", ''), (New-Object Text.UTF8Encoding $false)) }

if (-not $Kubectl) { $Kubectl = if (Get-Command oc -ErrorAction SilentlyContinue) { 'oc' } else { 'kubectl' } }
# kubectl's stderr must not stop the script (PowerShell 5.1 turns it into an error under Stop); callers check $LASTEXITCODE
function K { $ErrorActionPreference = 'Continue'; if ($MyInvocation.ExpectingInput) { $input | & $Kubectl @args } else { & $Kubectl @args } }
if (-not $AuthUrl) { $AuthUrl = if ($Hcs) { "https://iam-apigateway-proxy.$Cloud/v3" } else { "https://iam.$Cloud/v3" } }
if ($ApiRateLimit -lt 0) { $ApiRateLimit = if ($Hcs) { 0.5 } else { 0 } }
$EVS = "evs.$Region.$Cloud"; $ECS = "ecs.$Region.$Cloud"

# ---------------------------------------------------------------- 1 cluster
Say "cluster"
$server = K config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>$null
K get --raw /readyz 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-Install "$Kubectl cannot reach the cluster; log in first" }
$openshift = [bool](K api-resources --api-group=security.openshift.io -o name 2>$null)
Say "  $server ($(if ($openshift) { 'OpenShift' } else { 'Kubernetes' }))"

# ---------------------------------------------------------------- 2 overlay
function Render-Overlay {
  $img = ''
  if ($Image) {
    if ($Image -match '^(.+)@(sha256:[0-9a-f]{64})$') { $img = "- name: evs-csi-plugin`n  newName: $($Matches[1])`n  digest: $($Matches[2])`n" }
    elseif ($Image -match '^(.+/[^:/]+):([^:/]+)$') { $img = "- name: evs-csi-plugin`n  newName: $($Matches[1])`n  newTag: $($Matches[2])`n" }
    else { $img = "- name: evs-csi-plugin`n  newName: $Image`n" }
  }
  $patches = ''
  if ($GatewayIp) {
    WriteLf (Join-Path $gen 'hosts.yaml') "- op: add`n  path: /spec/template/spec/hostAliases`n  value:`n  - ip: $GatewayIp`n    hostnames: [$EVS, $ECS]`n"
    $patches = "patches:`n- path: hosts.yaml`n  target: {kind: Deployment, name: csi-evs-controller}`n- path: hosts.yaml`n  target: {kind: DaemonSet, name: csi-evs-plugin}`n"
  }
  WriteLf (Join-Path $gen 'kustomization.yaml') ("# generated by install.ps1`napiVersion: kustomize.config.k8s.io/v1beta1`nkind: Kustomization`nresources:`n- ../base`n" + $(if ($img) { "images:`n$img" } else { '' }) + $patches)
}
Render-Overlay

if ($Uninstall) {
  Say 'uninstall driver'
  if ($DryRun) { K delete -k $gen --ignore-not-found --dry-run=server; exit 0 }
  K delete -k $gen --ignore-not-found --wait=true
  K -n $KS delete configmap evs-csi-install --ignore-not-found | Out-Null
  Say 'done: cloud-config secret, StorageClasses, PVs and disks were left in place'
  exit 0
}
if (-not $Image) { Stop-Install '-Image is required (a driver build, best pinned by digest)' }

# ---------------------------------------------------------------- 3 TLS
$tls = 'system'; $caPem = ''
function Pem($cert) { "-----BEGIN CERTIFICATE-----`n" + ([Convert]::ToBase64String($cert.RawData, 'InsertLineBreaks') -replace "`r", '') + "`n-----END CERTIFICATE-----`n" }
function Sha256($cert) { $h = [Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData); ($h | ForEach-Object { $_.ToString('X2') }) -join ':' }
if ($Insecure) { $tls = 'insecure' }
elseif ($CaFile) {
  $caPem = [IO.File]::ReadAllText((Resolve-Path $CaFile).Path)
  if ($caPem -notmatch '-----BEGIN CERTIFICATE-----') { Stop-Install "$CaFile holds no PEM certificate" }
  $tls = 'ca-file'
}
elseif ($FetchCa) {
  $h, $p = $FetchCa -split ':'; if (-not $p) { $p = 443 }
  Say "  reading the certificate chain from ${h}:$p (name $EVS)"
  $script:chainCerts = @()
  $tcp = New-Object Net.Sockets.TcpClient($h, [int]$p)
  $cb = [Net.Security.RemoteCertificateValidationCallback] { param($s, $cert, $chain, $err)
    $script:chainCerts = @($chain.ChainElements | ForEach-Object { New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $_.Certificate.RawData) }); $true }
  $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $cb)
  $ssl.AuthenticateAsClient($EVS); $ssl.Dispose(); $tcp.Dispose()
  if (-not $script:chainCerts) { Stop-Install "no certificate chain from ${h}:$p" }
  $root = $script:chainCerts[-1]
  $fp = Sha256 $root
  Say "  root CA: $($root.Subject)"
  Say "  SHA-256: $fp"
  if ($root.Subject -ne $root.Issuer) { Stop-Install "the server did not send its root CA ($($root.Issuer)); get it from your cloud operator and use -CaFile" }
  if (-not $CaFingerprint) { Stop-Install 'confirm this fingerprint with your cloud operator, then run again with -CaFingerprint <the value above>' }
  if (($CaFingerprint -replace '[^0-9A-Fa-f]', '').ToUpper() -ne ($fp -replace ':', '')) { Stop-Install "fingerprint does not match -CaFingerprint: not trusting this CA" }
  $caPem = Pem $root; $tls = 'ca-file'
}
Say "  TLS: $tls"

# ---------------------------------------------------------------- 4 cloud-config secret
if (-not $KeepSecret) {
  if (-not $CredentialsCsv) { Stop-Install '-CredentialsCsv is required (or -KeepSecret to keep the existing secret)' }
  $row = Import-Csv $CredentialsCsv | Select-Object -First 1
  $ak = $row.'Access Key Id'; $sk = $row.'Secret Access Key'
  if (-not $ak -or -not $sk) { Stop-Install "no 'Access Key Id' / 'Secret Access Key' in $CredentialsCsv" }
  $lines = @('[Global]', "region=$Region", "cloud=$Cloud", "auth-url=$AuthUrl", "project-id=$ProjectId",
    "access-key=$ak", "secret-key=$sk", "insecure=$(([string]($tls -eq 'insecure')).ToLower())")
  if ($tls -eq 'ca-file') { $lines += 'ca-file=/etc/evs/ca.crt' }
  if ($Hcs) { $lines += 'hcs=true'; $lines += 'skip-catalog=true' }
  if ($ApiRateLimit -gt 0) { $lines += "api-rate-limit=$([string]$ApiRateLimit)"; $lines += "api-burst=$ApiBurst" }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "cc-$([guid]::NewGuid())"; New-Item -ItemType Directory $tmp | Out-Null
  try {
    WriteLf (Join-Path $tmp 'cloud-config') (($lines -join "`n") + "`n")
    $from = @("--from-file=cloud-config=$(Join-Path $tmp 'cloud-config')")
    if ($caPem) { WriteLf (Join-Path $tmp 'ca.crt') $caPem; $from += "--from-file=ca.crt=$(Join-Path $tmp 'ca.crt')" }
    $y = K -n $KS create secret generic cloud-config @from --dry-run=client -o yaml
    if ($DryRun) { Say '  cloud-config (keys hidden):'; $lines | ForEach-Object { if ($_ -match '^(access|secret)-key=') { "    $($_ -replace '=.*$', '=******')" } else { "    $_" } } | Write-Host }
    else { $y | K apply -f - | Out-Null; if ($LASTEXITCODE -ne 0) { Stop-Install 'writing the cloud-config secret failed' } }
  } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue; $ak = $null; $sk = $null; $lines = $null }
  Say "  secret $KS/cloud-config written (hcs=$([bool]$Hcs), api-rate-limit=$ApiRateLimit, tls=$tls)"
} else {
  K -n $KS get secret cloud-config -o name 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Stop-Install "-KeepSecret but $KS/cloud-config does not exist" }
  # the secret is not read: carry its non-secret settings over from what the last install recorded
  $prev = $null; $j = K -n $KS get configmap evs-csi-install -o json 2>$null
  if ($LASTEXITCODE -eq 0 -and $j) { $prev = ($j | Out-String | ConvertFrom-Json).data }
  $tls = if ($prev -and $prev.tls) { $prev.tls } else { 'unknown' }
  if ($prev -and $prev.'api-rate-limit') { $ApiRateLimit = [double]$prev.'api-rate-limit' }
  Say "  keeping the existing cloud-config secret (tls=$tls, api-rate-limit=$ApiRateLimit as last installed)"
}

# ---------------------------------------------------------------- 5 StorageClasses
$scMap = @()
if ($VolumeTypes) {
  $y = ''
  foreach ($pair in ($VolumeTypes -split ',')) {
    $az, $type = $pair.Trim() -split '='; $az = $az.Trim(); $type = $type.Trim()
    $name = 'evs-' + (($az.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))
    $scMap += "$az=$name"
    $y += @"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: $name}
provisioner: evs.csi.huaweicloud.com
parameters: {type: $type, csi.storage.k8s.io/fstype: $Fstype}
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
allowedTopologies:
- matchLabelExpressions: [{key: topology.evs.csi.huaweicloud.com/zone, values: [$az]}]
---

"@
  }
  WriteLf (Join-Path $gen 'storageclasses.yaml') $y
}

# ---------------------------------------------------------------- 6 apply
$cm = [ordered]@{ tls = $tls; hcs = ([string][bool]$Hcs).ToLower(); cloud = $Cloud; region = $Region; 'project-id' = $ProjectId
  'auth-url' = $AuthUrl; 'gateway-ip' = $GatewayIp; 'api-rate-limit' = [string]$ApiRateLimit; image = $Image
  storageclasses = ($scMap -join ','); 'volume-types' = $VolumeTypes; installed = (Get-Date).ToUniversalTime().ToString('o') }
$cmY = "apiVersion: v1`nkind: ConfigMap`nmetadata: {name: evs-csi-install, namespace: $KS}`ndata:`n" + (($cm.Keys | ForEach-Object { "  ${_}: '$($cm[$_] -replace "'", "''")'" }) -join "`n") + "`n"
WriteLf (Join-Path $gen 'evs-csi-install.yaml') $cmY
if (-not (K api-resources --api-group=snapshot.storage.k8s.io -o name 2>$null)) {
  Say '  WARNING: no snapshot.storage.k8s.io API: install the external-snapshotter CRDs and controller for snapshots'
}
if ($DryRun) {
  Say "dry run: rendered $gen"
  K apply -k $gen --dry-run=server
  if ($VolumeTypes) { K apply -f (Join-Path $gen 'storageclasses.yaml') --dry-run=server }
  exit 0
}
Say 'install driver'
K apply -k $gen; if ($LASTEXITCODE -ne 0) { Stop-Install 'applying the driver failed' }
if ($VolumeTypes) {
  foreach ($doc in ((Get-Content -Raw (Join-Path $gen 'storageclasses.yaml')) -split "`n---`n" | Where-Object { $_.Trim() })) {
    $n = [regex]::Match($doc, 'name: ([^}\s]+)').Groups[1].Value
    if (K get sc $n -o name 2>$null) { Say "  StorageClass $n exists: left as is (parameters cannot change in place)" }
    else { $doc | K apply -f - }
  }
}
K apply -f (Join-Path $gen 'evs-csi-install.yaml') | Out-Null
# a changed secret is only read at start
K -n $KS rollout restart deployment/csi-evs-controller daemonset/csi-evs-plugin | Out-Null
K -n $KS rollout status deployment/csi-evs-controller --timeout=600s
K -n $KS rollout status daemonset/csi-evs-plugin --timeout=900s
K -n $KS get pods -o wide | Where-Object { $_ -match '^NAME|csi-evs' }
Say "installed. Validate with: ./test.ps1"
