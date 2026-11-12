# evs-suite.ps1 - EVS CSI validation suite for OpenShift or Kubernetes on Huawei Cloud Stack or Huawei Cloud.
# 8 phases, ~134 tests. Each result is appended as one JSON line to -Results (id, phase, name, status, detail,
# seconds, metrics). Creates real EVS disks in each AZ given; every phase deletes what it made.
#   pwsh ./evs-suite.ps1 -Region xx-xxxx-1 -Cloud cloud.example.com -ProjectId <id> `
#     -StorageClasses 'az1=evs-az1,az2=evs-az2' -XfsType <volume-type> [-GatewayIp xx.xx.xx.xx] -Phases 1,2,3
# Needs oc (or kubectl via -Oc) logged in as cluster-admin. Phases 4-7 create and delete real EVS disks.
param(
  [string]$Phases = '1,2,3,4,5,6,7,8',   # comma list; powershell -File passes arrays as one string
  [string]$Results = 'suite-results.jsonl',
  [int]$LoadPerAz = 10,
  [Parameter(Mandatory)] [string]$Region,
  [Parameter(Mandatory)] [string]$Cloud,
  [Parameter(Mandatory)] [string]$ProjectId,
  # AZ=StorageClass for one or two AZs, each class pinned to its AZ
  [Parameter(Mandatory)] [string]$StorageClasses,
  # EVS volume type of the first AZ, for the XFS test class
  [Parameter(Mandatory)] [string]$XfsType,
  # set when evs/ecs names are pinned to the API gateway with hostAliases (overlays/hcs-gateway-hosts)
  [string]$GatewayIp = '',
  [string]$IamHost = '',
  [string]$Kubeconfig = '',
  [string]$Oc = ''
)
$PhaseList = @($Phases -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Kubeconfig) { $env:KUBECONFIG = $Kubeconfig }
if (-not $Oc) { $Oc = (Get-Command oc -ErrorAction Stop).Source }
if (-not [IO.Path]::IsPathRooted($Results)) { $Results = Join-Path $here $Results }
$UTF8 = New-Object Text.UTF8Encoding $false

$EVS = "evs.$Region.$Cloud"
$ECS = "ecs.$Region.$Cloud"
$IAM = if ($IamHost) { $IamHost } else { "iam-apigateway-proxy.$Cloud" }
$GW = $GatewayIp
$SCOF = [ordered]@{}; foreach ($p in ($StorageClasses -split ',')) { $kv = $p.Trim() -split '='; $SCOF[$kv[0].Trim()] = $kv[1].Trim() }
if ($SCOF.Count -lt 1 -or $SCOF.Count -gt 2) { throw '-StorageClasses needs one or two AZ=class pairs' }
$AZS = @($SCOF.Keys); $AZ1 = $AZS[0]; $AZ2 = $AZS[-1]; $SingleAz = $AZS.Count -eq 1
$TAGOF = @{}; foreach ($z in $SCOF.Keys) { $TAGOF[$z] = ($z -replace '[^A-Za-z0-9]', '').Substring(0, 2).ToUpper() }
$HasStub = $false
$IMG = 'registry.access.redhat.com/ubi9/ubi-minimal'
$KS = 'kube-system'

# ---------------------------------------------------------------- helpers
function oc { & $Oc @args 2>$null }
function J { $t = & $Oc @args -o json 2>$null; if ($t) { ($t -join "`n") | ConvertFrom-Json } }
function X($ns, $pod, $cmd, $c = '') {
  if ($c) { @(& $Oc -n $ns exec $pod -c $c -- sh -c $cmd 2>$null) } else { @(& $Oc -n $ns exec $pod -- sh -c $cmd 2>$null) }
}
function UtcOf($ts) { if ($ts) { [DateTime]::Parse($ts).ToUniversalTime() } }
function Apply-Yaml($text) {
  $f = Join-Path ([IO.Path]::GetTempPath()) "evs-suite-$([guid]::NewGuid()).yaml"
  [IO.File]::WriteAllText($f, ($text -replace "`r", ''), $UTF8)
  & $Oc apply -f $f 2>$null | Out-Null
  Remove-Item $f -Force
}
function WaitUntil([scriptblock]$cond, [int]$timeout = 300, [int]$step = 5) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $timeout) { if ([bool](& $cond)) { return $true }; Start-Sleep $step }
  return [bool](& $cond)
}
function Stat($vals) {
  $v = @($vals | Where-Object { $_ -ne $null } | ForEach-Object { [double]$_ } | Sort-Object)
  if ($v.Count -eq 0) { return @{} }
  $p = { param($q) $v[[Math]::Min($v.Count - 1, [Math]::Floor($q * ($v.Count - 1) + 0.5))] }
  @{ n = $v.Count; min = $v[0]; p50 = (& $p 0.5); p95 = (& $p 0.95); max = $v[-1]; avg = [Math]::Round(($v | Measure-Object -Average).Average, 1) }
}
function DdRate($line) {
  # coreutils dd: "... copied, 3.2 s, 168 MB/s"  -> @{ sec; mbps }
  $m = [regex]::Match("$line", 'copied, ([\d.]+) s, ([\d.]+) ([kKMG]?B)/s')
  if (-not $m.Success) { return $null }
  $mult = switch ($m.Groups[3].Value.ToUpper()) { 'B' { 1e-6 } 'KB' { 1e-3 } 'MB' { 1 } 'GB' { 1000 } }
  @{ sec = [double]$m.Groups[1].Value; mbps = [Math]::Round([double]$m.Groups[2].Value * $mult, 1) }
}

$script:phase = ''
function Rec($id, $name, $status, $detail, $metrics, $sec) {
  $o = [ordered]@{ id = $id; phase = $script:phase; name = $name; status = $status; detail = "$detail"
    seconds = [Math]::Round($sec, 1); metrics = $metrics; ts = (Get-Date).ToUniversalTime().ToString('o') }
  [IO.File]::AppendAllText($Results, (($o | ConvertTo-Json -Compress -Depth 6) + "`n"), $UTF8)
  Write-Output ('{0,-4} {1,-8} {2}  | {3}' -f $status, $id, $name, $detail)
}
function T($id, $name, [scriptblock]$body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { $r = @(& $body) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1 }
  catch { $r = @{ s = 'FAIL'; d = "exception: $($_.Exception.Message)" } }
  if (-not $r) { $r = @{ s = 'FAIL'; d = 'test produced no result' } }
  Rec $id $name $r.s $r.d $r.m $sw.Elapsed.TotalSeconds
}
function Res($ok, $d, $m = $null) { if ($ok) { @{ s = 'PASS'; d = $d; m = $m } } else { @{ s = 'FAIL'; d = $d; m = $m } } }
function Warn($d, $m = $null) { @{ s = 'WARN'; d = $d; m = $m } }
function Phase($name) { $script:phase = $name; Write-Output ''; Write-Output "=== $name ===" }

function Ns($ns, [switch]$Privileged) {
  $lab = if ($Privileged) { "  labels: {pod-security.kubernetes.io/enforce: privileged, pod-security.kubernetes.io/warn: privileged, pod-security.kubernetes.io/audit: privileged}`n" } else { '' }
  Apply-Yaml "apiVersion: v1`nkind: Namespace`nmetadata:`n  name: $ns`n$lab"
  if ($Privileged) {
    Apply-Yaml @"
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: suite-privileged, namespace: $ns}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: 'system:openshift:scc:privileged'}
subjects: [{kind: ServiceAccount, name: default, namespace: $ns}]
"@
  }
}
function Drop-Ns($ns) {
  oc -n $ns delete pod --all --wait=true --timeout=300s | Out-Null
  oc -n $ns delete sts --all --wait=true --timeout=120s | Out-Null
  oc -n $ns delete pod --all --wait=true --timeout=300s | Out-Null
  oc -n $ns delete volumesnapshot --all --wait=true --timeout=300s | Out-Null
  oc -n $ns delete pvc --all --wait=true --timeout=600s | Out-Null
  oc delete namespace $ns --wait=false | Out-Null
}
function PvcYaml($ns, $name, $sc, $size = '10Gi', $access = 'ReadWriteOnce', $mode = 'Filesystem', $src = '') {
  $ds = if ($src) { "  dataSource: {name: $src, kind: VolumeSnapshot, apiGroup: snapshot.storage.k8s.io}`n" } else { '' }
  "apiVersion: v1`nkind: PersistentVolumeClaim`nmetadata: {name: $name, namespace: $ns}`nspec:`n  accessModes: [$access]`n  volumeMode: $mode`n  storageClassName: $sc`n$ds  resources: {requests: {storage: $size}}`n"
}
function PodYaml($ns, $name, $claim, $node = '', $cmd = 'sleep infinity', [switch]$Block, [switch]$Priv) {
  $sel = if ($node) { "  nodeSelector: {kubernetes.io/hostname: $node}`n" } else { '' }
  $sc = if ($Priv) { 'privileged: true' } else { 'allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}' }
  $mnt = if ($Block) { 'volumeDevices: [{name: d, devicePath: /dev/xvdz}]' } else { 'volumeMounts: [{name: d, mountPath: /data}]' }
  "apiVersion: v1`nkind: Pod`nmetadata: {name: $name, namespace: $ns, labels: {suite: evs}}`nspec:`n$sel  terminationGracePeriodSeconds: 5`n  containers:`n  - name: c`n    image: $IMG`n    command: [sh, -c, '$cmd']`n    securityContext: {$sc}`n    $mnt`n  volumes: [{name: d, persistentVolumeClaim: {claimName: $claim}}]`n"
}
function PodReady($ns, $pod) { (oc -n $ns get pod $pod -o jsonpath='{.status.containerStatuses[0].ready}') -eq 'true' }
function WaitReady($ns, $pod, $timeout = 300) { WaitUntil { PodReady $ns $pod } $timeout 5 }
function ReadyLatency($ns, $pod) {
  $o = J -n $ns get pod $pod
  $c = $o.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }
  if ($c) { [Math]::Round(((UtcOf $c.lastTransitionTime) - (UtcOf $o.metadata.creationTimestamp)).TotalSeconds, 1) }
}
function PvOf($ns, $pvc) { oc -n $ns get pvc $pvc -o jsonpath='{.spec.volumeName}' }
function PvcPhase($ns, $pvc) { oc -n $ns get pvc $pvc -o jsonpath='{.status.phase}' }
function DfKb($ns, $pod) {
  # @() keeps a one-line result an array; a bare string would make $l[-1] its last character
  $l = @(X $ns $pod 'df -k /data | tail -1')
  if ($l.Count) { [double](($l[-1] -split '\s+')[1]) } else { 0 }
}
function ShaOk($ns, $pod, $file) { (X $ns $pod "sha256sum -c $file.sha 2>&1") -match ': OK' }
function Patch-Size($ns, $pvc, $size) {
  $p = '{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"' + $size + '\"}}}}'
  oc -n $ns patch pvc $pvc -p $p | Out-Null
}
function Workers {
  # schedulable nodes that are not control-plane, grouped by the zone the EVS node plugin reported
  $m = @{}
  foreach ($n in (J get nodes).items) {
    $l = $n.metadata.labels
    if ($l.'node-role.kubernetes.io/control-plane' -ne $null -or $l.'node-role.kubernetes.io/master' -ne $null) {
      if ($l.'node-role.kubernetes.io/worker' -eq $null) { continue }
    }
    if ($n.spec.unschedulable) { continue }
    $z = $l.'topology.evs.csi.huaweicloud.com/zone'; if (-not $z) { continue }
    if (-not $m.ContainsKey($z)) { $m[$z] = @() }
    $m[$z] += $n.metadata.name
  }
  $m
}
function MetaAz {
  # AZ per node from the HCS metadata service, read through each hostNetwork node plugin pod (Alpine wget)
  $m = @{}
  foreach ($p in (J -n $KS get pods -l app=csi-evs-plugin).items) {
    $md = (X $KS $p.metadata.name 'wget -qO- -T 5 http://169.254.169.254/openstack/latest/meta_data.json' 'evs-csi-plugin') -join ''
    $m[$p.spec.nodeName] = [regex]::Match($md, '"availability_zone":\s*"([^"]+)"').Groups[1].Value
  }
  $m
}
function Run-Probe($name, $aliasesJson, $bash) {
  $ind = ($bash -replace "`r", '' -split "`n" | ForEach-Object { "      $_" }) -join "`n"
  Apply-Yaml "apiVersion: v1`nkind: Pod`nmetadata: {name: $name, namespace: $KS}`nspec:`n  restartPolicy: Never`n  hostAliases: $aliasesJson`n  containers:`n  - name: p`n    image: registry.access.redhat.com/ubi9/ubi`n    command: [bash, -c]`n    args:`n    - |`n$ind`n"
  WaitUntil { (oc -n $KS get pod $name -o jsonpath='{.status.phase}') -in 'Succeeded', 'Failed' } 180 3 | Out-Null
  $out = oc -n $KS logs $name
  oc -n $KS delete pod $name --wait=false | Out-Null
  $kv = @{}
  foreach ($l in $out) { if ("$l" -match '^KV (\w+)=(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim() } }
  $kv
}

function AllResults {
  # phases may run in parallel into suite-results*.jsonl: merge, latest result per id wins
  $rows = Get-ChildItem (Split-Path $Results) -Filter 'suite-results*.jsonl' | ForEach-Object { Get-Content $_.FullName } | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } | Sort-Object { [DateTime]::Parse($_.ts) }
  $latest = @{}; foreach ($r in $rows) { $latest[$r.id] = $r }; $latest
}
$HasStub = [bool](oc -n $KS get deploy evs-iam-stub -o name)
$W = Workers
$ALLNODES = @(oc get nodes -o name | ForEach-Object { $_ -replace '^node/', '' })
Write-Output "Suite start $(Get-Date -Format o); workers: $(($W.Keys | ForEach-Object { "$_=$($W[$_] -join ',')" }) -join '; ')"

# ================================================================ 1 Platform
if ($PhaseList -contains 1) {
  Phase '1 Platform'
  $cd = J get csidriver evs.csi.huaweicloud.com
  T 'P01' 'CSIDriver evs.csi.huaweicloud.com registered' { Res ([bool]$cd) "found=$([bool]$cd)" }
  T 'P02' 'CSIDriver attachRequired and podInfoOnMount' { Res ($cd.spec.attachRequired -and $cd.spec.podInfoOnMount) "attachRequired=$($cd.spec.attachRequired) podInfoOnMount=$($cd.spec.podInfoOnMount)" }
  $dep = J -n $KS get deploy csi-evs-controller
  T 'P03' 'Controller Deployment available' { Res ($dep.status.readyReplicas -eq $dep.spec.replicas -and $dep.spec.replicas -ge 1) "ready=$($dep.status.readyReplicas)/$($dep.spec.replicas)" }
  $cp = (J -n $KS get pods -l app=csi-evs-provisioner).items | Where-Object { -not $_.metadata.deletionTimestamp } | Select-Object -First 1
  T 'P04' 'Controller pod: all containers ready' { $r = @($cp.status.containerStatuses | Where-Object { $_.ready }).Count; $t = @($cp.status.containerStatuses).Count; Res ($r -eq $t -and $t -ge 6) "$r/$t ready ($($cp.metadata.name))" }
  T 'P05' 'Controller pod: zero restarts' { $n = ($cp.status.containerStatuses | Measure-Object -Property restartCount -Sum).Sum; Res ($n -eq 0) "restarts=$n" @{ restarts = $n } }
  $ds = J -n $KS get ds csi-evs-plugin
  T 'P06' 'Node plugin DaemonSet ready on every node' { Res ($ds.status.numberReady -eq $ds.status.desiredNumberScheduled -and $ds.status.desiredNumberScheduled -eq $ALLNODES.Count) "ready=$($ds.status.numberReady)/$($ds.status.desiredNumberScheduled), nodes=$($ALLNODES.Count)" }
  $np = (J -n $KS get pods -l app=csi-evs-plugin).items
  T 'P07' 'Node plugin pods: zero restarts' { $n = ($np | ForEach-Object { $_.status.containerStatuses } | Measure-Object -Property restartCount -Sum).Sum; Res ($n -eq 0) "restarts=$n across $(@($np).Count) pods" @{ restarts = $n } }
  $csin = (J get csinode).items
  T 'P08' 'CSINode registration on all nodes' { $n = @($csin | Where-Object { $_.spec.drivers.name -contains 'evs.csi.huaweicloud.com' }).Count; Res ($n -eq $ALLNODES.Count) "$n/$($ALLNODES.Count) nodes" }
  T 'P09' 'Attachable volume limit published per node' {
    $al = @{}; foreach ($c in $csin) { $d = $c.spec.drivers | Where-Object { $_.name -eq 'evs.csi.huaweicloud.com' }; if ($d) { $al[$c.metadata.name] = $d.allocatable.count } }
    $min = ($al.Values | Measure-Object -Minimum).Minimum; Res ($min -ge 1) "min=$min per node" @{ allocatable = $al }
  }
  T 'P10' 'Leader election: all 4 sidecar/driver leases held by live controller' {
    # with several controller replicas any live one may lead; right after a rollout the leases still name the old
    # pods until they expire, so allow the handover time
    $script:held = 0; $script:lc = 0; $script:nl = 0
    WaitUntil {
      $live = @((J -n $KS get pods -l app=csi-evs-provisioner).items | Where-Object { -not $_.metadata.deletionTimestamp } | ForEach-Object { $_.metadata.name })
      $ls = @((J -n $KS get lease).items | Where-Object { $_.metadata.name -match 'evs' })
      $script:held = @($ls | Where-Object { $live -contains $_.spec.holderIdentity }).Count; $script:lc = $live.Count; $script:nl = $ls.Count
      $script:held -eq 4
    } 120 5 | Out-Null
    Res ($script:held -eq 4) "$($script:held)/$($script:nl) leases held by live controllers ($($script:lc) replicas)"
  }
  T 'P11' 'Driver image pinned by digest in both workloads' {
    $i1 = ($dep.spec.template.spec.containers | Where-Object { $_.name -eq 'evs-csi-provisioner' }).image
    $i2 = ($ds.spec.template.spec.containers | Where-Object { $_.name -eq 'evs-csi-plugin' }).image
    Res ($i1 -match '@sha256:' -and $i1 -eq $i2) ($i1 -replace '^.*@', '')
  }
  T 'P12' 'Every driver pod runs the configured image digest' {
    $want = (($dep.spec.template.spec.containers | Where-Object { $_.name -eq 'evs-csi-provisioner' }).image -replace '^.*@', '')
    $st = @((J -n $KS get pods -l 'app in (csi-evs-provisioner,csi-evs-plugin)').items | ForEach-Object { $_.status.containerStatuses } | Where-Object { $_.name -in 'evs-csi-provisioner', 'evs-csi-plugin' })
    # a container started from an @sha256 reference runs exactly that content; imageID may name the per-platform digest
    $bad = @($st | Where-Object { -not $_.ready -or ($_.image -notmatch [regex]::Escape($want) -and $_.imageID -notmatch [regex]::Escape($want)) })
    if ($want -notmatch '^sha256:') { return (Warn 'driver image not pinned by digest (see P11)') }
    Res ($st.Count -gt 0 -and $bad.Count -eq 0) "$($st.Count - $bad.Count)/$($st.Count) driver containers on $($want.Substring(0, 19))"
  }
  T 'P13' 'IAM catalog stub Deployment ready' { if (-not $HasStub) { return (Res $true 'IAM stub not used (skip-catalog)') }; $s = J -n $KS get deploy evs-iam-stub; Res ($s.status.readyReplicas -ge 1) "ready=$($s.status.readyReplicas)" }
  T 'P14' 'IAM catalog stub Service has endpoints' { if (-not $HasStub) { return (Res $true 'IAM stub not used (skip-catalog)') }; $e = oc -n $KS get endpoints evs-iam-stub -o jsonpath='{.subsets[*].addresses[*].ip}'; Res ([bool]$e) "endpoints=$e" }
  T 'P15' 'cloud-config secret present' { $k = oc -n $KS get secret cloud-config -o jsonpath='{.metadata.name}'; Res ($k -eq 'cloud-config') 'kube-system/cloud-config (contents not read)' }
  foreach ($az in $AZS) {
    $id = if ($az -eq $AZ1) { 'P16' } else { 'P17' }
    T $id "StorageClass $($SCOF[$az]) correct for $az" {
      $s = J get sc $SCOF[$az]
      $ok = $s.provisioner -eq 'evs.csi.huaweicloud.com' -and $s.volumeBindingMode -eq 'WaitForFirstConsumer' -and $s.allowVolumeExpansion -and ($s.allowedTopologies.matchLabelExpressions.values -contains $az) -and $s.parameters.type
      Res $ok "type=$($s.parameters.type) fstype=$($s.parameters.'csi.storage.k8s.io/fstype') binding=$($s.volumeBindingMode) expand=$($s.allowVolumeExpansion) topology=$($s.allowedTopologies.matchLabelExpressions.values)"
    }
  }
  T 'P18' 'Privileged SCC only for the node plugin' {
    $rb = @((J -n $KS get rolebinding).items | Where-Object { $_.metadata.name -like 'csi-evs-*' })
    $nodePriv = @($rb | Where-Object { $_.roleRef.name -eq 'system:openshift:scc:privileged' -and $_.subjects.name -contains 'csi-evs-node-sa' }).Count
    $ctlPriv = @($rb | Where-Object { $_.roleRef.name -eq 'system:openshift:scc:privileged' -and $_.subjects.name -contains 'csi-evs-controller-sa' }).Count
    Res ($nodePriv -eq 1 -and $ctlPriv -eq 0) "node plugin privileged=$nodePriv, controller privileged=$ctlPriv"
  }
  T 'P23' 'Driver service accounts cannot read Secrets' {
    $a = oc auth can-i list secrets --all-namespaces --as=system:serviceaccount:kube-system:csi-evs-node-sa
    $b = oc auth can-i get secrets -n kube-system --as=system:serviceaccount:kube-system:csi-evs-controller-sa
    Res ($a -eq 'no' -and $b -eq 'no') "node list secrets=$a, controller get secrets=$b"
  }
  T 'P24' 'Controller runs non-root with a read-only root filesystem' {
    $sc = $dep.spec.template.spec.securityContext; $cs = @($dep.spec.template.spec.containers)
    $ro = @($cs | Where-Object { $_.securityContext.readOnlyRootFilesystem -and $_.securityContext.allowPrivilegeEscalation -eq $false }).Count
    Res ($sc.runAsNonRoot -and $sc.runAsUser -ne 0 -and $ro -eq $cs.Count) "runAsUser=$($sc.runAsUser), hardened containers=$ro/$($cs.Count)"
  }
  T 'P19' 'hostAliases (evs/ecs/iam) in both driver workloads' {
    $a = @($dep.spec.template.spec.hostAliases.hostnames) + @($ds.spec.template.spec.hostAliases.hostnames)
    if (-not $GW) { return (Res (@($a | Where-Object { $_ }).Count -eq 0) "$(@($a | Where-Object { $_ }).Count) host entries (none expected without -GatewayIp)") }
    $ok = (@($a | Where-Object { $_ -eq $EVS }).Count -eq 2) -and (@($a | Where-Object { $_ -eq $ECS }).Count -eq 2) -and (-not $HasStub -or @($a | Where-Object { $_ -eq $IAM }).Count -eq 2)
    Res $ok "$(@($a).Count) host entries"
  }
  T 'P20' 'Node plugin on host network (metadata route)' { Res ($ds.spec.template.spec.hostNetwork -eq $true) "hostNetwork=$($ds.spec.template.spec.hostNetwork)" }
  T 'P21' 'Controller log clean (60m): no x509 / DNS / timeout / panic' {
    $lg = oc -n $KS logs deploy/csi-evs-controller -c evs-csi-provisioner --since=60m
    $bad = @($lg | Where-Object { $_ -match 'x509|no such host|i/o timeout|panic|APIGW\.0301|Response Code: 401|Response Code: 403' }).Count
    Res ($bad -eq 0) "$bad matching lines in $(@($lg).Count)" @{ log_lines = @($lg).Count; bad = $bad }
  }
  T 'P22' 'Node plugins: NodeGetInfo/metadata errors absent (10m)' {
    $bad = 0; foreach ($p in $np) { $bad += @(oc -n $KS logs $p.metadata.name -c evs-csi-plugin --since=10m | Where-Object { $_ -match 'Unable to retrieve instance id|NodeGetInfo, error' }).Count }
    Res ($bad -eq 0) "$bad error lines across $(@($np).Count) pods"
  }
}

# ================================================================ 2 Network
if ($PhaseList -contains 2) {
  Phase '2 Network & endpoints'
  $aliases = oc -n $KS get deploy csi-evs-controller -o jsonpath='{.spec.template.spec.hostAliases}'
  $probe = @'
E=__EVS__; C=__ECS__; I=__IAM__; P=__PROJECT__; Z=00000000-0000-0000-0000-000000000000
echo KV dns_evs=$(getent hosts $E | awk '{print $1}')
echo KV dns_ecs=$(getent hosts $C | awk '{print $1}')
echo KV dns_iam=$(getent hosts $I | awk '{print $1}')
echo KV https_evs=$(curl -sk -o /dev/null -m8 -w '%{http_code}' https://$E/)
echo KV https_ecs=$(curl -sk -o /dev/null -m8 -w '%{http_code}' https://$C/)
echo KV san=$(echo | timeout 6 openssl s_client -connect $E:443 -servername $E 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -d ' ')
echo KV catalog=$(curl -sk -m6 https://$I/v3/auth/catalog | tr -d ' ')
r(){ curl -sk -o /dev/null -m8 -X $1 -H Content-Type:application/json -d {} -w '%{http_code}' https://$2$3; }
echo KV r_create=$(r POST $E /v2/$P/volumes)
echo KV r_extend=$(r POST $E /v2/$P/volumes/$Z/action)
echo KV r_get=$(r GET $E /v2/$P/cloudvolumes/$Z)
echo KV r_list=$(r GET $E /v2/$P/cloudvolumes/detail)
echo KV r_delete=$(r DELETE $E /v2/$P/cloudvolumes/$Z)
echo KV r_snap=$(r GET $E /v2/$P/cloudsnapshots/detail)
echo KV r_attach=$(r POST $C /v1/$P/cloudservers/$Z/attachvolume)
echo KV r_bdlist=$(r GET $C /v1/$P/cloudservers/$Z/block_device)
echo KV r_job=$(r GET $C /v1/$P/jobs/$Z)
echo KV pod_md=$(curl -s -o /dev/null -m4 -w '%{http_code}' http://169.254.169.254/openstack/latest/meta_data.json)
'@
  $kv = Run-Probe 'evs-suite-probe' $aliases ($probe.Replace('__EVS__', $EVS).Replace('__ECS__', $ECS).Replace('__IAM__', $IAM).Replace('__PROJECT__', $ProjectId))
  T 'N01' 'DNS: EVS endpoint resolves (driver path)' { Res ($kv.dns_evs -and (-not $GW -or $kv.dns_evs -eq $GW)) "$EVS -> $($kv.dns_evs)" }
  T 'N02' 'DNS: ECS endpoint resolves (driver path)' { Res ($kv.dns_ecs -and (-not $GW -or $kv.dns_ecs -eq $GW)) "$ECS -> $($kv.dns_ecs)" }
  T 'N03' 'DNS: IAM name resolves to catalog stub' { if (-not $HasStub) { return (Res $true 'IAM stub not used (skip-catalog)') }; $sip = oc -n $KS get svc evs-iam-stub -o jsonpath='{.spec.clusterIP}'; Res ($kv.dns_iam -eq $sip) "$IAM -> $($kv.dns_iam) (stub $sip)" }
  T 'N04' 'HTTPS: EVS gateway reachable' { Res ($kv.https_evs -and $kv.https_evs -ne '000') "HTTP $($kv.https_evs)" }
  T 'N05' 'HTTPS: ECS gateway reachable' { Res ($kv.https_ecs -and $kv.https_ecs -ne '000') "HTTP $($kv.https_ecs)" }
  T 'N06' "TLS: gateway certificate covers *.$Region.$Cloud" { Res ($kv.san -match ('\*\.' + [regex]::Escape("$Region.$Cloud"))) $kv.san }
  T 'N07' 'IAM catalog stub answers GET /v3/auth/catalog' { if (-not $HasStub) { return (Res $true 'IAM stub not used (skip-catalog)') }; Res ($kv.catalog -match '"catalog":\[\]') $kv.catalog }
  $routes = [ordered]@{ N08 = @('r_create', 'EVS create  POST /v2/{p}/volumes'); N09 = @('r_extend', 'EVS extend  POST /v2/{p}/volumes/{id}/action')
    N10 = @('r_get', 'EVS get  GET /v2/{p}/cloudvolumes/{id}'); N11 = @('r_list', 'EVS list  GET /v2/{p}/cloudvolumes/detail')
    N12 = @('r_delete', 'EVS delete  DELETE /v2/{p}/cloudvolumes/{id}'); N13 = @('r_attach', 'ECS attach  POST /v1/{p}/cloudservers/{id}/attachvolume')
    N14 = @('r_bdlist', 'ECS block devices  GET /v1/{p}/cloudservers/{id}/block_device'); N15 = @('r_job', 'ECS jobs  GET /v1/{p}/jobs/{id}') }
  foreach ($k in $routes.Keys) {
    $key = $routes[$k][0]; $label = $routes[$k][1]
    T $k "Gateway route published: $label" { $c = $kv[$key]; Res ($c -eq '401') "HTTP $c (401 = route exists, needs signature)" @{ http = $c } }
  }
  $script:META = MetaAz
  $i = 16
  foreach ($n in ($ALLNODES | Sort-Object)) {
    T ('N{0:D2}' -f $i) "Metadata service reachable from node plugin on $n" { $z = $script:META[$n]; Res ([bool]$z) "availability_zone=$z" }
    $i++
  }
  T ('N{0:D2}' -f $i) 'Pod network to metadata (169.254.169.254)' {
    if ($kv.pod_md -eq '200') { Res $true 'reachable from pod network' } else { Warn "HTTP $($kv.pod_md): not reachable from the pod network; the node plugin uses hostNetwork for it" }
  }
}

# ================================================================ 3 Topology
if ($PhaseList -contains 3) {
  Phase '3 Topology'
  if (-not $script:META) { $script:META = MetaAz }
  $i = 1
  foreach ($n in ($ALLNODES | Sort-Object)) {
    T ('T{0:D2}' -f $i) "Zone labels agree with metadata on $n" {
      $ev = oc get node $n -o jsonpath='{.metadata.labels.topology\.evs\.csi\.huaweicloud\.com/zone}'
      $kz = oc get node $n -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
      $md = $script:META[$n]
      Res ($ev -and $ev -eq $kz -and $ev -eq $md) "evs=$ev k8s=$kz metadata=$md"
    }
    $i++
  }
  T 'T09' "$AZ1 has >= 2 schedulable workers (in-AZ failover)" { $c = @($W[$AZ1]).Count; Res ($c -ge 2) "$c workers: $($W[$AZ1] -join ', ')" @{ workers = $c } }
  T 'T10' "$AZ2 has >= 2 schedulable workers (in-AZ failover)" { $c = @($W[$AZ2]).Count; Res ($c -ge 2) "$c workers: $($W[$AZ2] -join ', ')" @{ workers = $c } }
}

# ================================================================ 4 Functional per AZ
if ($PhaseList -contains 4) {
  Phase '4 Functional (per AZ)'
  $ns = 'evs-suite-func'; Ns $ns
  foreach ($az in $AZS) {
    $tg = $TAGOF[$az]; $sc = $SCOF[$az]; $n1 = $W[$az][0]; $n2 = $W[$az][1]
    $pvc = "f-$($tg.ToLower())"; $pod = $pvc
    T "F$tg-01" "[$az] WaitForFirstConsumer: PVC stays Pending without a pod" {
      Apply-Yaml (PvcYaml $ns $pvc $sc); Start-Sleep 15
      $ph = PvcPhase $ns $pvc; Res ($ph -eq 'Pending' -and -not (PvOf $ns $pvc)) "phase=$ph after 15s, no PV"
    }
    T "F$tg-02" "[$az] Dynamic provisioning creates EVS disk on first consumer" {
      Apply-Yaml (PodYaml $ns $pod $pvc $n1)
      $ok = WaitUntil { (PvcPhase $ns $pvc) -eq 'Bound' } 300 3
      $script:fpv = PvOf $ns $pvc
      $pt = UtcOf (J -n $ns get pod $pod).metadata.creationTimestamp; $vt = UtcOf (J get pv $script:fpv).metadata.creationTimestamp
      $lat = if ($pt -and $vt) { [Math]::Round(($vt - $pt).TotalSeconds, 1) }
      Res $ok "PV $($script:fpv) in ${lat}s" @{ provision_s = $lat; az = $az }
    }
    $pvo = J get pv $script:fpv
    T "F$tg-03" "[$az] PV node affinity pinned to $az" { $v = $pvo.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values; Res ($v -contains $az) "affinity=$v" }
    T "F$tg-04" "[$az] PV volumeHandle is an EVS disk UUID" { $h = $pvo.spec.csi.volumeHandle; Res ($h -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') "evs disk $h" @{ disk = $h } }
    T "F$tg-05" "[$az] Attach + mount: pod Ready" { $ok = WaitReady $ns $pod 300; $l = ReadyLatency $ns $pod; Res $ok "ready in ${l}s from pod creation on $n1" @{ ready_s = $l; az = $az } }
    T "F$tg-06" "[$az] VolumeAttachment attached to scheduled node" {
      $va = (J get volumeattachment).items | Where-Object { $_.spec.source.persistentVolumeName -eq $script:fpv }
      Res ($va.status.attached -and $va.spec.nodeName -eq $n1) "node=$($va.spec.nodeName) attached=$($va.status.attached)"
    }
    T "F$tg-07" "[$az] Filesystem ext4 mounted at /data" { $m = (X $ns $pod 'grep /data /proc/mounts') -join ' '; Res ($m -match ' /data ext4 ') $m }
    T "F$tg-08" "[$az] Capacity ~10Gi visible in pod" { $kb = DfKb $ns $pod; Res ($kb -gt 9.5e6) ('{0:N2} GiB' -f ($kb / 1MB)) @{ size_gib = [Math]::Round($kb / 1MB, 2) } }
    T "F$tg-09" "[$az] Non-root container can write (fsGroup)" { $o = X $ns $pod 'id -u; touch /data/nonroot && echo WROTE'; Res (($o -contains 'WROTE') -and $o[0] -ne '0') "uid=$($o[0])" }
    T "F$tg-10" "[$az] Write 256MiB random data + checksum" {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $o = X $ns $pod 'head -c 268435456 /dev/urandom > /data/blob && sync && sha256sum /data/blob > /data/blob.sha && sha256sum -c /data/blob.sha'
      Res ($o -match ': OK') "$($o -join ' ') in $([Math]::Round($sw.Elapsed.TotalSeconds,1))s"
    }
    T "F$tg-11" "[$az] Pod recreated on same node: data intact" {
      oc -n $ns delete pod $pod --wait=true --timeout=180s | Out-Null; Apply-Yaml (PodYaml $ns $pod $pvc $n1)
      $ok = (WaitReady $ns $pod 300) -and (ShaOk $ns $pod '/data/blob'); $l = ReadyLatency $ns $pod
      Res $ok "ready in ${l}s, checksum OK=$ok" @{ remount_s = $l; az = $az }
    }
    T "F$tg-12" "[$az] Pod moved to ${n2}: detach/re-attach, data intact" {
      if (-not $n2) { return (Warn "only one worker in ${az}: move between nodes not tested") }
      oc -n $ns delete pod $pod --wait=true --timeout=180s | Out-Null; Apply-Yaml (PodYaml $ns $pod $pvc $n2)
      $ok = (WaitReady $ns $pod 420) -and (ShaOk $ns $pod '/data/blob'); $l = ReadyLatency $ns $pod
      Res $ok "$n1 -> $n2, ready in ${l}s, checksum OK=$ok" @{ move_s = $l; az = $az }
    }
    foreach ($step in @(@('13', '20Gi', 19.0), @('14', '30Gi', 28.5))) {
      $sid = $step[0]; $size = $step[1]; $minG = $step[2]
      T "F$tg-$sid" "[$az] Online expansion to $size (pod running)" {
        $sw = [Diagnostics.Stopwatch]::StartNew(); Patch-Size $ns $pvc $size
        $ok = WaitUntil { ((oc -n $ns get pvc $pvc -o jsonpath='{.status.capacity.storage}') -eq $size) -and ((DfKb $ns $pod) / 1MB -gt $minG) } 420 5
        $rs = oc -n $ns get pod $pod -o jsonpath='{.status.containerStatuses[0].restartCount}'
        Res ($ok -and $rs -eq '0') ('fs {0:N1} GiB in {1:N0}s, restarts={2}' -f ((DfKb $ns $pod) / 1MB), $sw.Elapsed.TotalSeconds, $rs) @{ expand_s = [Math]::Round($sw.Elapsed.TotalSeconds, 1); az = $az }
      }
    }
    T "F$tg-15" "[$az] Data intact after expansions" { Res (ShaOk $ns $pod '/data/blob') 'sha256 OK' }
    T "F$tg-16" "[$az] Delete PVC: disk deleted (reclaim Delete), attachment removed" {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      oc -n $ns delete pod $pod --wait=true --timeout=180s | Out-Null; oc -n $ns delete pvc $pvc --wait=false | Out-Null
      $ok = WaitUntil { -not (oc get pv $script:fpv -o name) } 420 5
      $va = @((J get volumeattachment).items | Where-Object { $_.spec.source.persistentVolumeName -eq $script:fpv }).Count
      Res ($ok -and $va -eq 0) ('PV gone in {0:N0}s, attachments left={1}' -f $sw.Elapsed.TotalSeconds, $va) @{ delete_s = [Math]::Round($sw.Elapsed.TotalSeconds, 1); az = $az }
    }
  }
  Drop-Ns $ns
}

# ================================================================ 5 Advanced
if ($PhaseList -contains 5) {
  Phase '5 Advanced volume features'
  $ns = 'evs-suite-adv'; Ns $ns -Privileged
  $st1 = $W[$AZ1][0]; $rc1 = $W[$AZ2][0]
  Apply-Yaml @"
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: evs-suite-xfs}
provisioner: evs.csi.huaweicloud.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters: {type: $XfsType, csi.storage.k8s.io/fstype: xfs}
allowedTopologies: [{matchLabelExpressions: [{key: topology.evs.csi.huaweicloud.com/zone, values: [$AZ1]}]}]
"@
  T 'A01' 'XFS StorageClass: provision + mount xfs' {
    Apply-Yaml ((PvcYaml $ns 'xfs' 'evs-suite-xfs') + "---`n" + (PodYaml $ns 'xfs' 'xfs' $st1))
    $ok = WaitReady $ns 'xfs' 420; $m = (X $ns 'xfs' 'grep /data /proc/mounts') -join ' '
    Res ($ok -and $m -match ' /data xfs ') $m @{ ready_s = (ReadyLatency $ns 'xfs') }
  }
  T 'A02' 'XFS online expansion 10Gi -> 15Gi (xfs_growfs)' {
    Patch-Size $ns 'xfs' '15Gi'; $ok = WaitUntil { (DfKb $ns 'xfs') / 1MB -gt 14 } 420 5
    Res $ok ('fs {0:N1} GiB' -f ((DfKb $ns 'xfs') / 1MB))
  }
  T 'A03' 'Raw block volume (volumeMode Block) presented to pod' {
    Apply-Yaml ((PvcYaml $ns 'blk' $SCOF[$AZ2] '10Gi' 'ReadWriteOnce' 'Block') + "---`n" + (PodYaml $ns 'blk' 'blk' $rc1 -Block -Priv))
    $ok = WaitReady $ns 'blk' 420; $o = X $ns 'blk' 'test -b /dev/xvdz && echo IS_BLOCK'
    Res ($ok -and ($o -contains 'IS_BLOCK')) "/dev/xvdz block=$($o -contains 'IS_BLOCK')"
  }
  T 'A04' 'Raw block I/O: 64MiB direct write/read-back checksum' {
    $o = X $ns 'blk' 'head -c 67108864 /dev/urandom > /tmp/r; dd if=/tmp/r of=/dev/xvdz bs=1M oflag=direct 2>/dev/null; dd if=/dev/xvdz of=/tmp/b bs=1M count=64 iflag=direct 2>/dev/null; sha256sum /tmp/r /tmp/b'
    $h = @($o | ForEach-Object { ($_ -split '\s+')[0] }); Res ($h.Count -eq 2 -and $h[0] -eq $h[1]) "written=$($h[0].Substring(0,12))… read=$("$($h[1])".Substring(0,[Math]::Min(12,"$($h[1])".Length)))…"
  }
  $sts = @'
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: sts, namespace: evs-suite-adv}
spec:
  serviceName: sts
  replicas: 2
  selector: {matchLabels: {app: sts}}
  template:
    metadata: {labels: {app: sts}}
    spec:
      terminationGracePeriodSeconds: 5
      containers:
      - name: c
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: [sh, -c, 'echo started-$HOSTNAME >> /data/who; sync; sleep infinity']
        volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec: {accessModes: [ReadWriteOnce], storageClassName: __SC2__, resources: {requests: {storage: 10Gi}}}
'@
  $sts = $sts.Replace('__SC2__', $SCOF[$AZ2])
  T 'A05' "StatefulSet: one EVS disk per replica (2 replicas, $AZ2)" {
    Apply-Yaml $sts; $ok = WaitUntil { (oc -n $ns get sts sts -o jsonpath='{.status.readyReplicas}') -eq '2' } 600 5
    $h = @('data-sts-0', 'data-sts-1' | ForEach-Object { $p = PvOf $ns $_; if ($p) { oc get pv $p -o jsonpath='{.spec.csi.volumeHandle}' } })
    Res ($ok -and $h.Count -eq 2 -and $h[0] -ne $h[1]) "disks: $($h -join ', ')"
  }
  T 'A06' 'StatefulSet scale 2 -> 0 -> 2 reuses the same disks' {
    oc -n $ns scale sts sts --replicas=0 | Out-Null; WaitUntil { -not (oc -n $ns get pods -l app=sts -o name) } 300 5 | Out-Null
    oc -n $ns scale sts sts --replicas=2 | Out-Null; $ok = WaitUntil { (oc -n $ns get sts sts -o jsonpath='{.status.readyReplicas}') -eq '2' } 600 5
    $w = @(X $ns 'sts-0' 'cat /data/who'); Res ($ok -and $w.Count -ge 2) "sts-0 start log lines=$($w.Count)"
  }
  T 'A07' 'ReadWriteMany request is not usable (driver is single-node writer)' {
    Apply-Yaml ((PvcYaml $ns 'rwx' $SCOF[$AZ1] '10Gi' 'ReadWriteMany') + "---`n" + (PodYaml $ns 'rwx' 'rwx' $st1)); Start-Sleep 90
    $ph = PvcPhase $ns 'rwx'
    if ($ph -ne 'Bound') { Res $true "phase=${ph}: RWX not provisioned" } else { Warn 'RWX PVC binds (driver does not reject at create); restrict RWX on evs classes by policy' }
  }
  T 'A08' "Cross-AZ guard: $AZ1 disk cannot be used from $AZ2 node" {
    if ($SingleAz) { return (Warn 'one AZ given: cross-AZ guard not tested') }
    oc -n $ns delete pod xfs --wait=true --timeout=180s | Out-Null; Apply-Yaml (PodYaml $ns 'guard' 'xfs' $rc1); Start-Sleep 30
    $ph = oc -n $ns get pod guard -o jsonpath='{.status.phase}'
    $ev = (oc -n $ns get events --field-selector involvedObject.name=guard -o jsonpath='{.items[*].message}')
    Res ($ph -eq 'Pending' -and $ev -match 'affinity|conflict') "phase=$ph; $(([string]$ev).Substring(0, [Math]::Min(140, ([string]$ev).Length)))"
  }
  oc -n $ns delete pod guard --wait=false | Out-Null
  Apply-Yaml @'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata: {name: evs-snap, labels: {velero.io/csi-volumesnapshot-class: "true"}}
driver: evs.csi.huaweicloud.com
deletionPolicy: Retain
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata: {name: evs-suite-snap}
driver: evs.csi.huaweicloud.com
deletionPolicy: Delete
'@
  T 'A09' 'Snapshot API: CRDs, controller and VolumeSnapshotClasses present' {
    $crd = [bool](oc get crd volumesnapshots.snapshot.storage.k8s.io -o name); $c = @(oc get volumesnapshotclass -o name | Where-Object { $_ -match 'evs' }).Count
    Res ($crd -and $c -ge 2) "crd=$crd evs classes=$c"
  }
  T 'A10' 'Snapshot of a live volume becomes readyToUse' {
    Apply-Yaml "apiVersion: snapshot.storage.k8s.io/v1`nkind: VolumeSnapshot`nmetadata: {name: snap1, namespace: $ns}`nspec: {volumeSnapshotClassName: evs-suite-snap, source: {persistentVolumeClaimName: data-sts-0}}`n"
    $ok = WaitUntil { (oc -n $ns get volumesnapshot snap1 -o jsonpath='{.status.readyToUse}') -eq 'true' } 420 5
    $err = oc -n $ns get volumesnapshot snap1 -o jsonpath='{.status.error.message}'
    Res $ok $(if ($ok) { 'readyToUse=true' } else { "not ready: $err" })
  }
  T 'A11' 'Restore PVC from snapshot: data matches source' {
    if ((oc -n $ns get volumesnapshot snap1 -o jsonpath='{.status.readyToUse}') -ne 'true') { return (Res $false 'skipped: snapshot not ready') }
    Apply-Yaml ((PvcYaml $ns 'restore' $SCOF[$AZ2] '10Gi' 'ReadWriteOnce' 'Filesystem' 'snap1') + "---`n" + (PodYaml $ns 'restore' 'restore' $rc1))
    $ok = WaitReady $ns 'restore' 600; $a = (X $ns 'restore' 'cat /data/who') -join ','; $b = (X $ns 'sts-0' 'cat /data/who') -join ','
    Res ($ok -and $a -and $b.StartsWith($a)) "restored: $a"
  }
  T 'A12' 'Snapshot delete removes VolumeSnapshotContent (Delete policy)' {
    $vsc = oc -n $ns get volumesnapshot snap1 -o jsonpath='{.status.boundVolumeSnapshotContentName}'
    oc -n $ns delete pod restore --wait=true --timeout=180s | Out-Null; oc -n $ns delete pvc restore --wait=false | Out-Null
    oc -n $ns delete volumesnapshot snap1 --wait=false | Out-Null
    $ok = if ($vsc) { WaitUntil { -not (oc get volumesnapshotcontent $vsc -o name) } 300 5 } else { $false }
    Res $ok "content $vsc removed=$ok"
  }
  Drop-Ns $ns
  oc delete sc evs-suite-xfs | Out-Null; oc delete volumesnapshotclass evs-suite-snap | Out-Null
}

# ================================================================ 6 Resilience
if ($PhaseList -contains 6) {
  Phase '6 Resilience'
  $ns = 'evs-suite-res'; Ns $ns
  $n1 = $W[$AZ1][0]; $n2 = $W[$AZ1][1]
  $live = 'while true; do date >> /data/live.log; sync; sleep 1; done'
  Apply-Yaml ((PvcYaml $ns 'live' $SCOF[$AZ1]) + "---`n" + (PodYaml $ns 'live' 'live' $n1 $live))
  function Lines { [int]((X $ns 'live' 'wc -l < /data/live.log') -join '') }
  T 'R01' 'Baseline: app writing continuously to EVS volume' { $ok = WaitReady $ns 'live' 420; Start-Sleep 10; $a = Lines; Start-Sleep 5; $b = Lines; Res ($ok -and $b -gt $a) "lines $a -> $b" }
  T 'R02' 'Node plugin killed on app node: app I/O continues' {
    $pp = oc -n $KS get pods -l app=csi-evs-plugin --field-selector "spec.nodeName=$n1" -o jsonpath='{.items[0].metadata.name}'
    $a = Lines; oc -n $KS delete pod $pp --wait=false | Out-Null; Start-Sleep 20; $b = Lines
    Res ($b -ge $a + 10) "plugin $pp deleted; lines $a -> $b in 20s"
  }
  T 'R03' 'Node plugin recovers and re-registers' {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = WaitUntil { $p = (J -n $KS get pods -l app=csi-evs-plugin --field-selector "spec.nodeName=$n1").items | Where-Object { -not $_.metadata.deletionTimestamp }; $p -and @($p[0].status.containerStatuses | Where-Object { -not $_.ready }).Count -eq 0 } 180 3
    Res $ok ('ready in {0:N0}s' -f $sw.Elapsed.TotalSeconds) @{ plugin_recover_s = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
  }
  T 'R04' 'Controller pod killed: replacement takes all leases' {
    $old = oc -n $KS get pods -l app=csi-evs-provisioner -o jsonpath='{.items[0].metadata.name}'; $sw = [Diagnostics.Stopwatch]::StartNew()
    oc -n $KS delete pod $old --wait=false | Out-Null
    $ok = WaitUntil { $ls = (J -n $KS get lease).items | Where-Object { $_.metadata.name -match 'evs' }; @($ls | Where-Object { $_.spec.holderIdentity -and $_.spec.holderIdentity -ne $old }).Count -eq 4 } 300 3
    Res $ok ('failover in {0:N0}s (old {1})' -f $sw.Elapsed.TotalSeconds, $old) @{ failover_s = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
  }
  T 'R05' "Provisioning works after controller failover ($AZ2)" {
    Apply-Yaml ((PvcYaml $ns 'after' $SCOF[$AZ2]) + "---`n" + (PodYaml $ns 'after' 'after' $W[$AZ2][0]))
    $ok = WaitReady $ns 'after' 420; Res $ok "ready in $(ReadyLatency $ns 'after')s" @{ ready_s = (ReadyLatency $ns 'after') }
  }
  T 'R06' 'IAM stub pod killed: stub recovers, provisioning unaffected' { if (-not $HasStub) { return (Res $true 'IAM stub not used (skip-catalog)') };
    oc -n $KS delete pod -l app=evs-iam-stub --wait=false | Out-Null
    Apply-Yaml ((PvcYaml $ns 'stubtest' $SCOF[$AZ1]) + "---`n" + (PodYaml $ns 'stubtest' 'stubtest' $n2))
    $s = WaitUntil { (oc -n $KS get deploy evs-iam-stub -o jsonpath='{.status.readyReplicas}') -eq '1' } 180 3
    $ok = WaitReady $ns 'stubtest' 420; Res ($s -and $ok) "stub ready=$s, new volume ready=$ok"
  }
  T 'R07' 'Controller cold start: all replicas deleted at once' {
    $sw = [Diagnostics.Stopwatch]::StartNew(); oc -n $KS delete pod -l app=csi-evs-provisioner --wait=false | Out-Null; Start-Sleep 5
    $ok = WaitUntil { $d = J -n $KS get deploy csi-evs-controller; $want = $d.spec.replicas; $d.status.readyReplicas -eq $want -and $d.status.updatedReplicas -eq $want -and $d.status.replicas -eq $want } 300 3
    Res $ok ('controller ready in {0:N0}s' -f $sw.Elapsed.TotalSeconds) @{ coldstart_s = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
  }
  T 'R08' 'Pod deletion detaches disk (VolumeAttachment removed)' {
    $pv = PvOf $ns 'live'; $script:liveLines = Lines; $sw = [Diagnostics.Stopwatch]::StartNew()
    oc -n $ns delete pod live --wait=true --timeout=180s | Out-Null
    $ok = WaitUntil { @((J get volumeattachment).items | Where-Object { $_.spec.source.persistentVolumeName -eq $pv }).Count -eq 0 } 300 3
    Res $ok ('detached in {0:N0}s' -f $sw.Elapsed.TotalSeconds) @{ detach_s = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
  }
  T 'R09' "Re-attach on the other $AZ1 node: no data lost" {
    if (-not $n2) { return (Warn "only one worker in ${AZ1}: re-attach on another node not tested") }
    Apply-Yaml (PodYaml $ns 'live' 'live' $n2 $live); $ok = WaitReady $ns 'live' 420; $n = Lines
    Res ($ok -and $n -ge $script:liveLines) "lines before=$($script:liveLines) after=$n on $n2" @{ ready_s = (ReadyLatency $ns 'live') }
  }
  Drop-Ns $ns
}

# ================================================================ 7 Heavy load
if ($PhaseList -contains 7) {
  Phase '7 Heavy load'
  $ns = 'evs-suite-load'; Ns $ns
  $cmd = 'W=$(dd if=/dev/zero of=/data/load bs=1M count=512 oflag=direct 2>&1 | tail -1); echo W: $W; R=$(dd if=/data/load of=/dev/null bs=1M iflag=direct 2>&1 | tail -1); echo R: $R; sha256sum /data/load > /data/load.sha; echo C: $(sha256sum -c /data/load.sha); echo DONE; sleep infinity'
  $names = @(); $yaml = ''
  foreach ($az in $AZS) {
    for ($i = 1; $i -le $LoadPerAz; $i++) {
      $n = ('l-{0}-{1:D2}' -f $TAGOF[$az].ToLower(), $i); $names += $n
      $yaml += (PvcYaml $ns $n $SCOF[$az]) + "---`n" + (PodYaml $ns $n $n '' $cmd) + "---`n"
    }
  }
  $t0 = Get-Date; Apply-Yaml $yaml
  T 'L01' "Burst provisioning: $($names.Count) PVCs at once (both AZs) all Bound" {
    $ok = WaitUntil { @($names | Where-Object { (PvcPhase $ns $_) -ne 'Bound' }).Count -eq 0 } 1200 10
    $lat = foreach ($n in $names) { $c = J -n $ns get pvc $n; $p = PvOf $ns $n; if ($p) { [Math]::Round(((UtcOf (J get pv $p).metadata.creationTimestamp) - (UtcOf $c.metadata.creationTimestamp)).TotalSeconds, 1) } }
    $bound = @($names | Where-Object { (PvcPhase $ns $_) -eq 'Bound' }).Count
    Res $ok "$bound/$($names.Count) bound" @{ provision = (Stat $lat); provision_all = @($lat) }
  }
  T 'L02' "Burst attach: all $($names.Count) pods Ready" {
    $ok = WaitUntil { @($names | Where-Object { -not (PodReady $ns $_) }).Count -eq 0 } 1500 10
    $lat = foreach ($n in $names) { ReadyLatency $ns $n }; $ready = @($names | Where-Object { PodReady $ns $_ }).Count
    Res $ok "$ready/$($names.Count) ready" @{ ready = (Stat $lat); ready_all = @($lat) }
  }
  T 'L03' 'No provisioning/attach failures during burst' {
    $ev = (J -n $ns get events).items | Where-Object { $_.reason -in 'ProvisioningFailed', 'FailedAttachVolume', 'FailedMount' }
    $n = ($ev | Measure-Object -Property count -Sum).Sum; if (-not $n) { $n = 0 }
    $why = @($ev | Group-Object reason | ForEach-Object { "$($_.Name) x$(($_.Group | Measure-Object -Property count -Sum).Sum)" }) -join ', '
    $first = @($ev | Sort-Object { $_.lastTimestamp } | Select-Object -First 3 | ForEach-Object { "$($_.reason): $(($_.message -replace '\s+', ' ').Substring(0, [Math]::Min(160, $_.message.Length)))" })
    $first | ForEach-Object { Write-Host "    $_" }
    if ($n -eq 0) { Res $true '0 failure events' } else { Warn "$n retried failure events ($why; all recovered: $((@($names | Where-Object { PodReady $ns $_ }).Count) -eq $names.Count))" @{ failures = $n; reasons = $why; samples = $first } }
  }
  T 'L04' "Concurrent sequential write: $($names.Count) x 512MiB direct" {
    WaitUntil { @($names | Where-Object { -not ((oc -n $ns logs $_) -contains 'DONE') }).Count -eq 0 } 1200 10 | Out-Null
    $script:LD = @{}; foreach ($n in $names) { $lg = oc -n $ns logs $n; $script:LD[$n] = @{ w = DdRate (($lg | Where-Object { $_ -like 'W:*' }) -join ''); r = DdRate (($lg | Where-Object { $_ -like 'R:*' }) -join ''); c = (($lg | Where-Object { $_ -like 'C:*' }) -join '') -match 'OK' } }
    $w = @($script:LD.Values | ForEach-Object { $_.w.mbps }); $ok = @($w | Where-Object { $_ }).Count -eq $names.Count
    $per = @{}; foreach ($n in $names) { $per[$n] = $script:LD[$n].w.mbps }
    Res $ok ('{0} writers, per-volume p50 {1} MB/s, sum {2:N0} MB/s' -f @($w).Count, (Stat $w).p50, ($w | Measure-Object -Sum).Sum) @{ write_mbps = (Stat $w); write_by_pod = $per }
  }
  T 'L05' 'Concurrent sequential read-back (direct)' {
    $r = @($script:LD.Values | ForEach-Object { $_.r.mbps }); $per = @{}; foreach ($n in $names) { $per[$n] = $script:LD[$n].r.mbps }
    Res (@($r | Where-Object { $_ }).Count -eq $names.Count) ('per-volume p50 {0} MB/s, sum {1:N0} MB/s' -f (Stat $r).p50, ($r | Measure-Object -Sum).Sum) @{ read_mbps = (Stat $r); read_by_pod = $per }
  }
  T 'L06' 'Data integrity after concurrent load (sha256 on all volumes)' { $bad = @($names | Where-Object { -not $script:LD[$_].c }); Res ($bad.Count -eq 0) "$($names.Count - $bad.Count)/$($names.Count) OK $($bad -join ',')" }
  foreach ($az in $AZS) {
    $p = ('l-{0}-01' -f $TAGOF[$az].ToLower()); $id = if ($az -eq $AZ1) { 'L07' } else { 'L08' }
    T $id "[$az] 4KiB direct random-size IOPS (write 20k ops, read 20k ops)" {
      $wl = (X $ns $p 'dd if=/dev/zero of=/data/iops bs=4k count=20000 oflag=direct 2>&1 | tail -1') -join ''
      $rl = (X $ns $p 'dd if=/data/iops of=/dev/null bs=4k iflag=direct 2>&1 | tail -1') -join ''
      $w = DdRate $wl; $r = DdRate $rl
      $wi = if ($w) { [Math]::Round(20000 / $w.sec) }; $ri = if ($r) { [Math]::Round(20000 / $r.sec) }
      Res ($wi -and $ri) "write $wi IOPS, read $ri IOPS (QD1)" @{ write_iops = $wi; read_iops = $ri; az = $az }
    }
  }
  T 'L09' 'Attach density per node within published limit' {
    $va = (J get volumeattachment).items | Where-Object { $_.spec.attacher -eq 'evs.csi.huaweicloud.com' -and $_.status.attached }
    $per = @{}; foreach ($v in $va) { $per[$v.spec.nodeName] = 1 + [int]$per[$v.spec.nodeName] }
    $max = ($per.Values | Measure-Object -Maximum).Maximum; Res ($max -le 24) "max $max volumes on one node (limit 24)" @{ per_node = $per }
  }
  T 'L10' 'Controller healthy under load: no restarts, no failed calls from throttling or 5xx' {
    $since = [Math]::Max(60, [int]((Get-Date) - $t0).TotalSeconds + 60)
    # both replicas: only the leader works, but which one leads can change during the run
    $lg = @((J -n $KS get pods -l app=csi-evs-provisioner).items | ForEach-Object { oc -n $KS logs $_.metadata.name -c evs-csi-provisioner --since="${since}s" })
    $grpc = @($lg | Where-Object { $_ -match 'GRPC call:' }).Count
    # the driver retries a 429 itself ("429 Too Many Requests, retry n/m"); only throttling that reached a CSI
    # call as an error counts as a failure (HCS: APIGW.0308, a per-user limit such as 200 calls / 5 minutes)
    $retried = @($lg | Where-Object { $_ -match 'Too Many Requests, retry' }).Count
    $thr = @($lg | Where-Object { $_ -match 'APIGW\.0308|over ratelimit' -and $_ -notmatch 'Too Many Requests, retry' }).Count
    $e5 = @($lg | Where-Object { $_ -match 'Response Code: 5\d\d' }).Count
    $lim = ($lg | Where-Object { $_ -match 'limit:(\d+),time:([^"]+?)"' } | Select-Object -First 1 | ForEach-Object { if ($_ -match 'limit:(\d+),time:([^"]+?)"') { "$($Matches[1]) requests / $($Matches[2])" } })
    $rs = (J -n $KS get pods -l app=csi-evs-provisioner).items | ForEach-Object { $_.status.containerStatuses } | Measure-Object -Property restartCount -Sum
    $m = @{ csi_calls = $grpc; retried_429 = $retried; throttled = $thr; e5xx = $e5; restarts = $rs.Sum; rate_limit = $lim }
    if ($thr -eq 0 -and $e5 -eq 0) { Res $true "$grpc CSI calls, $retried calls retried after 429, 0 failed from throttling, 0 x 5xx, $($rs.Sum) restarts" $m }
    else { Warn "$thr CSI errors from throttling (APIGW.0308, limit $lim), $retried retried, 5xx=$e5, restarts=$($rs.Sum)" $m }
  }
  T 'L11' "Mass delete: $($names.Count) PVCs -> all EVS disks deleted" {
    $pvs = @($names | ForEach-Object { PvOf $ns $_ }); $sw = [Diagnostics.Stopwatch]::StartNew()
    oc -n $ns delete pod --all --wait=true --timeout=600s | Out-Null; oc -n $ns delete pvc --all --wait=false | Out-Null
    $ok = WaitUntil { @($pvs | Where-Object { oc get pv $_ -o name }).Count -eq 0 } 1200 10
    Res $ok ('{0}/{1} PVs gone in {2:N0}s' -f ($pvs.Count - @($pvs | Where-Object { oc get pv $_ -o name }).Count), $pvs.Count, $sw.Elapsed.TotalSeconds) @{ mass_delete_s = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
    $script:loadPvs = $pvs
  }
  T 'L12' 'All load VolumeAttachments cleaned up' { $n = @((J get volumeattachment).items | Where-Object { $script:loadPvs -contains $_.spec.source.persistentVolumeName }).Count; Res ($n -eq 0) "$n left" }
  Drop-Ns $ns
}

# ================================================================ 8 Production readiness
if ($PhaseList -contains 8) {
  Phase '8 Production readiness'
  $dep = J -n $KS get deploy csi-evs-controller; $ds = J -n $KS get ds csi-evs-plugin
  T 'PR01' 'TLS verification to the cloud APIs' {
    # the installer records the TLS mode in a ConfigMap; the suite never reads the cloud-config secret
    $tls = oc -n $KS get configmap evs-csi-install -o jsonpath='{.data.tls}'
    if ($tls -in 'ca-file', 'system') { Res $true "TLS verified ($tls)" }
    elseif ($tls -eq 'insecure') { Warn 'insecure=true: TLS not verified; install with -CaFile (or -FetchCa) to trust the cloud CA' }
    else { Warn 'unknown: evs-csi-install ConfigMap not found; check cloud-config has insecure=false or a ca-file' }
  }
  T 'PR02' 'Dedicated least-privilege HCS service user' { Warn 'review: the AK/SK must belong to an EVS/ECS-scoped service user, not an administrator, and be rotated on a schedule' }
  T 'PR03' 'No IAM workaround required' { if (-not $HasStub) { return (Res $true 'no IAM stub in use') }; Warn 'evs-iam-stub stands in for GET /v3/auth/catalog; set skip-catalog=true and remove the stub' }
  T 'PR04' 'Cloud endpoint DNS records' { if (-not $GW) { return (Res $true 'evs/ecs resolve through cluster DNS') }; Warn "evs/ecs names exist only as hostAliases -> $GW; add DNS records for $EVS and $ECS" }
  T 'PR05' 'Supported driver build' {
    $i = ($dep.spec.template.spec.containers | Where-Object { $_.name -like 'evs-csi-*' }).image
    Warn "driver image $($i -replace '@.*$', ''): whoever runs a build that is not an upstream release owns it until the changes are released"
  }
  T 'PR06' 'Driver image storage survives registry restart' {
    $i = ($dep.spec.template.spec.containers | Where-Object { $_.name -like 'evs-csi-*' }).image
    if ($i -notmatch '^image-registry\.openshift-image-registry\.svc') { return (Res $true "driver image is not in the internal registry ($($i -replace '/.*$', ''))") }
    $st = oc get configs.imageregistry.operator.openshift.io cluster -o jsonpath='{.spec.storage}'
    if ($st -match 'emptyDir') { @{ s = 'FAIL'; d = "internal registry storage ${st}: image lost on registry pod restart; use PVC/object storage or an external registry" } } else { Res $true $st }
  }
  T 'PR07' 'Images pinned by digest' { $i = ($dep.spec.template.spec.containers | Where-Object { $_.name -eq 'evs-csi-provisioner' }).image; Res ($i -match '@sha256:') ($i -replace '^.*@', '') }
  T 'PR08' 'Controller high availability' {
    $f = @((AllResults)['R04'] | Where-Object { $_ })
    $fo = if ($f) { " (measured failover $($f[0].metrics.failover_s)s)" } else { '' }
    if ($dep.spec.replicas -ge 2) { Res $true "replicas=$($dep.spec.replicas)" } else { Warn "replicas=1 with leader election$fo; add a 2nd replica + PodDisruptionBudget" }
  }
  T 'PR09' 'Resource requests on driver containers' {
    $all = @($dep.spec.template.spec.containers) + @($ds.spec.template.spec.containers); $no = @($all | Where-Object { -not $_.resources.requests }).Count
    if ($no -eq 0) { Res $true 'all containers have requests' } else { Warn "$no/$($all.Count) containers without CPU/memory requests" }
  }
  T 'PR10' 'Priority class on driver pods' {
    $c = $dep.spec.template.spec.priorityClassName; $n = $ds.spec.template.spec.priorityClassName
    if ($c -and $n) { Res $true "controller=$c node=$n" } else { Warn "controller=$c node=$(if ($n) { $n } else { '<none>' }): set system-node-critical on csi-evs-plugin" }
  }
  T 'PR11' 'Snapshots work for backup tooling (OADP)' {
    $c = [bool](oc get volumesnapshotclass evs-snap -o name); $a = (AllResults)['A10']
    if ($c -and $a -and $a.status -eq 'PASS') { Res $true 'evs-snap class present and snapshot test A10 passed' }
    else { @{ s = 'FAIL'; d = "evs-snap class present=$c, but snapshots fail (A10): HCS does not publish /v2/{p}/cloudsnapshots; patch the driver to use the published Cinder /v2/{p}/snapshots routes" } }
  }
  T 'PR12' 'Default StorageClass decided' {
    $d = @((J get sc).items | Where-Object { $_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true' } | ForEach-Object { $_.metadata.name })
    if ($d.Count -eq 1) { Res $true "default=$($d -join ',')" } else { Warn "default class(es): $(if ($d) { $d -join ',' } else { 'none' }); pick one evs class or keep classes explicit" }
  }
  T 'PR13' 'CSI monitoring and alerting' { $sm = @(oc get servicemonitor -A -o name | Where-Object { $_ -match 'evs' }).Count; if ($sm) { Res $true "$sm ServiceMonitors" } else { Warn 'no ServiceMonitor/alerts for csi-evs-*; add alerts on pod restarts, ProvisioningFailed and attach latency' } }
  T 'PR14' 'Metadata path without hostNetwork' { if (-not $ds.spec.template.spec.hostNetwork) { return (Res $true 'node plugin on the pod network') }; Warn 'node plugin runs hostNetwork for the 169.254.169.254 metadata service; check whether pods can reach it directly (N24)' }
  T 'PR15' 'Functional, resilience and load tests (phases 4-7) all pass' {
    $latest = @{}; $all = AllResults; foreach ($k in $all.Keys) { if ($k -match '^(F|A|R|L)[\w-]*\d') { $latest[$k] = $all[$k] } }
    $f = @($latest.Values | Where-Object { $_.status -eq 'FAIL' }).Count; $w = @($latest.Values | Where-Object { $_.status -eq 'WARN' }).Count
    if ($latest.Count -eq 0) { @{ s = 'FAIL'; d = 'no phase 4-7 results found' } } elseif ($f -eq 0) { Res $true "$($latest.Count) tests: 0 FAIL, $w WARN" } else { @{ s = 'FAIL'; d = "$($latest.Count) tests: $f FAIL, $w WARN" } }
  }
  T 'PR17' 'HCS API rate limit fits cluster-scale volume operations' {
    $l = @(Get-ChildItem (Split-Path $Results) -Filter 'suite-results*.jsonl' | ForEach-Object { Get-Content $_.FullName } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.id -eq 'L10' } | Sort-Object { [DateTime]::Parse($_.ts) } | Select-Object -Last 1)
    if (-not $l) { Warn 'no load-test result to judge the API rate limit' }
    elseif ($l[0].metrics.throttled -gt 0) { @{ s = 'FAIL'; d = "$($l[0].metrics.throttled) CSI calls failed from API throttling in the load burst (limit $($l[0].metrics.rate_limit)): lower api-rate-limit in cloud-config or raise the per-user API limit for the CSI user" } }
    elseif ($l[0].metrics.retried_429 -gt 0) { Res $true "$($l[0].metrics.retried_429) calls were throttled and retried by the driver; none failed" }
    else { Res $true 'no throttling in the load burst' }
  }
  T 'PR16' 'Vendor support position documented' { Warn 'review: platform vendor support position for a third-party CSI driver, and the cloud vendor''s position on the driver build' }
}

Write-Output ''
$latest = AllResults
Write-Output ('Suite totals (latest per test): {0} tests, PASS {1}, WARN {2}, FAIL {3}' -f $latest.Count, @($latest.Values | Where-Object { $_.status -eq 'PASS' }).Count, @($latest.Values | Where-Object { $_.status -eq 'WARN' }).Count, @($latest.Values | Where-Object { $_.status -eq 'FAIL' }).Count)
