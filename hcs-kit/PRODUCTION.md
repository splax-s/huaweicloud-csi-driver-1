# EVS CSI driver on Huawei Cloud Stack: production installation and validation

This guide takes a cluster from nothing to a validated, production-ready EVS CSI driver: what to prepare, how to
install, how to run the validation suite, what a good result looks like, and how to run the driver afterwards.
Everything here works on any Huawei Cloud Stack (HCS) or Huawei Cloud region and any OpenShift or Kubernetes
cluster on it. Site values appear as placeholders such as `xx-xxxx-1` and `cloud.example.com`.

## 1. Where the driver comes from

Until the HCS changes are merged upstream, production uses this fork and its image:

| What | Where |
|---|---|
| Driver source | `github.com/splax-s/huaweicloud-csi-driver-1`, branch `evs-hcs-support` |
| This kit | same repository, branch `hcs-install`, folder `hcs-kit/` |
| Driver image | `ghcr.io/splax-s/evs-csi-plugin`, tag `hcs-<commit>`, always deployed by digest |
| Upstream PR | from `evs-hcs-support` to `huaweicloud/huaweicloud-csi-driver` `master` |

When Huawei merges the PR and publishes a release image, move to that image with the steps in section 9.4.

## 2. Validated environment

The driver and this kit were validated end to end on 12 Nov 2026 on this environment:

| Component | Version |
|---|---|
| Cloud | Huawei Cloud Stack 8.6.1, one region, two availability zones |
| OpenShift | 4.22.18, channel `stable-4.22`, platform `None` (user-provisioned on HCS ECS) |
| Kubernetes | v1.35.8 |
| Node OS | Red Hat Enterprise Linux CoreOS 9.8.20261006-0 |
| Container runtime | CRI-O 1.35.9 |
| Network | OVN-Kubernetes |
| Nodes | 3 control plane and 5 workers (2 in one AZ, 3 in the other), 8 vCPU and 16 GiB each |
| Snapshot API | `snapshot.storage.k8s.io` v1, OpenShift's own snapshot controller |
| Driver | `evs-hcs-support`, image built from commit `4536ef4` (same code as the current head apart from a lint fix and docs) |

Sidecars, pinned by digest in `manifests/base/driver.yaml`:

| Sidecar | Version |
|---|---|
| csi-attacher | v4.13.0 |
| csi-provisioner | v6.4.0 |
| csi-snapshotter | v8.7.0 |
| csi-resizer | v2.3.0 |
| csi-node-driver-registrar | v2.18.0 |
| livenessprobe | v2.20.0 |

Older OpenShift 4.x and Kubernetes releases that still serve `snapshot.storage.k8s.io/v1` are expected to work,
but only the versions above were tested.

## 3. How it fits together

* **Controller**: a Deployment of 2 replicas in `kube-system`, 6 containers each (attacher, provisioner,
  snapshotter, resizer, liveness probe, driver). The sidecars elect one leader each, so the standby replica takes
  over within about 20 seconds if a pod dies. It runs as a non-root user with a read-only root filesystem and
  cannot read Secrets.
* **Node plugin**: a DaemonSet on every node, 3 containers (registrar, liveness probe, driver). It runs
  privileged and on the host network: privileged to format and mount disks, host network to reach the metadata
  service at `169.254.169.254`, which tells each node its AZ. On OVN-Kubernetes pods cannot reach that address
  from the pod network.
* **Cloud calls**: the controller creates, expands, snapshots and deletes disks through the EVS API
  (`https://evs.<region>.<cloud>`) and attaches and detaches them through the ECS API (`https://ecs.<region>.<cloud>`).
  It signs every call with an access key (AK/SK) stored in the `kube-system/cloud-config` Secret.
* **HCS mode**: `hcs=true` in `cloud-config` switches the driver to the API routes HCS publishes, and
  `skip-catalog=true` stops it calling the IAM service catalog, which HCS does not publish.

## 4. Before you start

### 4.1 From the cloud operator

| Item | Example | Notes |
|---|---|---|
| Cloud domain | `cloud.example.com` | The console address without the service prefix |
| Region | `xx-xxxx-1` | |
| Project ID | 32 hexadecimal characters | The resource space the disks are created in (My Credentials, Projects) |
| Service user and access key | `credentials.csv` | A user only for this driver, with EVS and ECS rights in that project and nothing else. Download the access key as `credentials.csv` |
| Volume type per AZ | `az1=type_01,az2=type_02` | As shown in the EVS console when you create a disk in each AZ |
| DNS records | `evs.xx-xxxx-1.cloud.example.com`, `ecs.xx-xxxx-1.cloud.example.com` | Both point at the API gateway. Without them, give the gateway IP to the installer (`-GatewayIp`) and it adds the names to the driver pods |
| Root CA fingerprint | `AB:CD:…` (SHA-256) | HCS signs its API gateway with its own root CA. Get the fingerprint from the operator, not from the gateway |
| API limit | 200 calls per 5 minutes per user | The HCS default. A higher limit for the service user makes large bursts faster; it is not required |
| Quota | at least 25 disks, 300 GiB and 5 snapshots | For the validation suite (section 7.4); add what production needs |

### 4.2 Cluster

* Cluster-admin access with `oc` (OpenShift) or `kubectl`.
* At least 2 schedulable workers in each AZ, so a pod can move to another node in its AZ. One worker per AZ
  works, but node moves are then not possible and the suite warns.
* Every node can reach the API gateway on TCP 443 and the metadata service `169.254.169.254` on TCP 80.
* The snapshot CRDs and a snapshot controller. OpenShift has both. Plain Kubernetes needs the external-snapshotter
  installed first.
* Nodes can pull from `ghcr.io` and `registry.k8s.io`. On a disconnected cluster, mirror the images first
  (section 5.2).

### 4.3 Workstation

* PowerShell: 5.1 or 7 on Windows, 7 on macOS or Linux (`brew install powershell`).
* `oc` or `kubectl` logged in to the cluster, and `git`.
* `credentials.csv`, kept off shared drives and never committed. The installer reads it once and does not print it.

## 5. Get the kit and the image

### 5.1 Clone

```bash
git clone -b hcs-install https://github.com/splax-s/huaweicloud-csi-driver-1.git
cd huaweicloud-csi-driver-1/hcs-kit
```

### 5.2 Resolve the image digest

Production pins the image by digest so every node runs exactly the same build. Read the digest of the tag for the
current `evs-hcs-support` head:

```bash
TAG=hcs-<commit>      # e.g. the first 7 characters of: git rev-parse origin/evs-hcs-support
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:splax-s/evs-csi-plugin:pull" | sed 's/.*"token":"\([^"]*\)".*/\1/')
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://ghcr.io/v2/splax-s/evs-csi-plugin/manifests/$TAG" | grep -i docker-content-digest
```

Use the result as `-Image ghcr.io/splax-s/evs-csi-plugin@sha256:<digest>`. The image covers `linux/amd64` and
`linux/arm64`.

Disconnected cluster: mirror the driver and the six sidecars (their references are in `manifests/base/driver.yaml`)
into your registry, keeping the digests, and pass the mirrored driver reference to `-Image`:

```bash
oc image mirror ghcr.io/splax-s/evs-csi-plugin@sha256:<digest> <registry>/evs-csi-plugin
```

Avoid keeping the only copy of the driver image in the cluster's internal registry if that registry stores its
data on an EVS disk: after a full cluster stop, the registry would need the driver to mount its disk, and the
driver would need the registry for its image.

## 6. Install

### 6.1 Dry run

Renders everything and has the API server validate it, without changing the cluster:

```bash
pwsh ./install.ps1 -Cloud cloud.example.com -Region xx-xxxx-1 -ProjectId <project id> -Hcs \
  -CredentialsCsv ./credentials.csv -VolumeTypes 'az1=type_01,az2=type_02' \
  -Image ghcr.io/splax-s/evs-csi-plugin@sha256:<digest> -GatewayIp xx.xx.xx.xx -FetchCa xx.xx.xx.xx -DryRun
```

On Windows PowerShell use the same line with a backtick (`` ` ``) instead of `\` at the line ends.

### 6.2 Trust the HCS root CA

Run the command without `-DryRun`. With `-FetchCa` and no fingerprint, the installer reads the certificate chain
the gateway sends, prints the root CA and its SHA-256 fingerprint, and stops:

```text
root CA: CN=root, OU=CloudService, O=Cloud, ...
SHA-256: 24:8B:A2:0D:...:25:19:BC
```

Compare the fingerprint with the one from the cloud operator. Only if they match, run again with
`-CaFingerprint <fingerprint>`. The installer then stores the root CA in the Secret as `ca.crt`, and the driver
verifies every API certificate against it. If you already have the CA as a PEM file, use `-CaFile ./ca.crt`
instead of `-FetchCa`. On public Huawei Cloud, whose certificates are publicly trusted, leave out all CA options.

### 6.3 Full install

```bash
pwsh ./install.ps1 -Cloud cloud.example.com -Region xx-xxxx-1 -ProjectId <project id> -Hcs \
  -CredentialsCsv ./credentials.csv -VolumeTypes 'az1=type_01,az2=type_02' \
  -Image ghcr.io/splax-s/evs-csi-plugin@sha256:<digest> -GatewayIp xx.xx.xx.xx \
  -FetchCa xx.xx.xx.xx -CaFingerprint <fingerprint>
```

Leave out `-GatewayIp` when the DNS records from section 4.1 exist. The install takes about two minutes. It ends
with the driver pods listed and `installed. Validate with: ./test.ps1`.

### 6.4 What the installer creates

| Object | Contents |
|---|---|
| Secret `kube-system/cloud-config` | `cloud-config` (region, cloud, auth URL, project, access key, `insecure=false`, `ca-file=/etc/evs/ca.crt`, `hcs=true`, `skip-catalog=true`, `api-rate-limit`, `api-burst`) and `ca.crt` |
| StorageClass `evs-<az>` per AZ | The AZ's volume type, `ext4`, `WaitForFirstConsumer`, expansion allowed, reclaim `Delete`, pinned to its AZ |
| Driver | Service accounts, RBAC, controller Deployment and PodDisruptionBudget, node DaemonSet, `CSIDriver`, VolumeSnapshotClass `evs-snap` (deletion policy `Retain`) |
| ConfigMap `kube-system/evs-csi-install` | The settings above without the key, for `test.ps1` |

An existing StorageClass with the same name is left as it is, because its parameters cannot be changed in place.

### 6.5 Installer options

| Option | Default | Meaning |
|---|---|---|
| `-Cloud`, `-Region`, `-ProjectId` | required | Where the disks are created |
| `-CredentialsCsv` | | Access key file; required unless `-KeepSecret` |
| `-Hcs` | off | Sets `hcs=true` and `skip-catalog=true`, and turns on API pacing |
| `-AuthUrl` | `https://iam-apigateway-proxy.<cloud>/v3` with `-Hcs`, otherwise `https://iam.<cloud>/v3` | IAM endpoint |
| `-VolumeTypes` | | `az=type,...`; one StorageClass per AZ |
| `-Fstype` | `ext4` | Filesystem of the StorageClasses |
| `-Image` | | Driver image, by digest |
| `-GatewayIp` | | Adds `evs`, `ecs` and IAM names to the driver pods when DNS lacks them |
| `-CaFile` / `-FetchCa` + `-CaFingerprint` | | CA to trust (section 6.2) |
| `-Insecure` | off | Turns TLS verification off. Not for production |
| `-ApiRateLimit` | `0.5` with `-Hcs`, otherwise off | API calls per second per controller pod |
| `-ApiBurst` | `50` | Calls that may go out at once before pacing starts |
| `-KeepSecret` | off | Keep the existing Secret (for image-only changes) |
| `-Uninstall` | | Removes the driver; leaves the Secret, StorageClasses, volumes and disks |
| `-DryRun` | | Render and validate only |
| `-Kubectl` | `oc` if found, else `kubectl` | Client to use |

Why 0.5 and 50: HCS allows 200 calls per user in any 5 minutes. A controller pod can send at most
`burst + rate × 300 s` = 50 + 150 = 200 calls in any 5 minutes, and a burst of 20 disks goes out without waiting.
Any call the gateway still rejects with `429` is retried up to 8 times, waiting 2 seconds and doubling to at most
60 seconds (or as long as the gateway's `Retry-After` says).

### 6.6 Check

```bash
oc -n kube-system get pods -o wide | grep csi-evs
oc get csidriver evs.csi.huaweicloud.com
oc get sc | grep evs-
```

Expect 2 controller pods at `6/6` and one node pod per node at `3/3`, all with 0 restarts.

## 7. Validate

### 7.1 Run

```bash
pwsh ./test.ps1 -Phases 1,2,3    # read-only checks, under a minute
pwsh ./test.ps1                  # all 8 phases, about 35 minutes
```

`test.ps1` takes every value from the `evs-csi-install` ConfigMap, so there is nothing to retype. Results go to
`results-<date>-<time>/`: `summary.txt` (totals and everything that did not pass), `suite.log` (every test with
its measurement) and `suite-results.jsonl` (machine-readable).

### 7.2 Phases

| Phase | Tests | Time | Touches the cluster |
|---|---|---|---|
| 1 Platform | 24 | 20 s | Read-only |
| 2 Network and endpoints | 24 (8 of them one per node) | 5 s | Read-only; unsigned calls to the gateway |
| 3 Topology | 10 (8 one per node) | 5 s | Read-only |
| 4 Functional, per AZ | 16 per AZ | 10 min | Creates, moves, expands and deletes one disk per AZ |
| 5 Advanced features | 12 | 6 min | XFS, raw block, StatefulSet, snapshots; temporary classes `evs-suite-xfs` and `evs-suite-snap` |
| 6 Resilience | 9 | 2 min | Deletes driver pods on purpose; attach and detach pause for a few seconds |
| 7 Heavy load | 12 | 9 min | 20 disks of 10 GiB at once (10 per AZ) |
| 8 Production readiness | 17 | seconds | Read-only review |

The test namespaces are `evs-suite-func`, `evs-suite-adv`, `evs-suite-res` and `evs-suite-load`. Each phase
deletes its namespace, disks and temporary classes when it finishes. Run phases 6 and 7 before go-live or in a
maintenance window.

### 7.3 What each test checks

**Phase 1, Platform**

| ID | Check |
|---|---|
| P01 | `CSIDriver evs.csi.huaweicloud.com` registered |
| P02 | `attachRequired` and `podInfoOnMount` set |
| P03 | Controller Deployment available |
| P04 | All controller containers ready |
| P05 | Controller: zero restarts |
| P06 | Node DaemonSet ready on every node |
| P07 | Node plugins: zero restarts |
| P08 | `CSINode` registration on every node |
| P09 | Attachable volume limit published per node |
| P10 | All 4 leader leases held by a live controller pod |
| P11 | Driver image pinned by digest, same in both workloads |
| P12 | Every driver pod runs that digest |
| P13, P14 | IAM catalog stub ready (passes as "not used" with `skip-catalog`) |
| P15 | `cloud-config` Secret present (contents not read) |
| P16, P17 | Each `evs-<az>` StorageClass: type, fstype, binding mode, expansion, AZ |
| P18 | Only the node plugin is privileged |
| P19 | Gateway host entries in both workloads (when `-GatewayIp` is used) |
| P20 | Node plugin on the host network |
| P21 | Controller log of the last hour free of x509, DNS, timeout and panic errors |
| P22 | Node plugin logs free of metadata errors |
| P23 | Driver service accounts cannot read Secrets |
| P24 | Controller runs non-root with a read-only root filesystem |

**Phase 2, Network and endpoints**

| ID | Check |
|---|---|
| N01, N02 | `evs` and `ecs` names resolve on the driver's path |
| N03 | IAM name resolves to the stub (passes as "not used" with `skip-catalog`) |
| N04, N05 | EVS and ECS gateways answer over HTTPS |
| N06 | Gateway certificate covers `*.<region>.<cloud>` |
| N07 | IAM stub answers the catalog call (passes as "not used") |
| N08–N12 | EVS routes published: create, extend, get, list, delete (`401` means the route exists) |
| N13–N15 | ECS routes published: attach, block devices, jobs |
| N16 onward | Metadata service reachable from the node plugin, one test per node |
| last N | Metadata from the pod network (expected warning on OVN-Kubernetes) |

**Phase 3, Topology**: one test per node that the node's zone labels match the AZ from the metadata service,
then one per AZ that it has at least 2 schedulable workers.

**Phase 4, Functional** (16 tests per AZ, `FST-` for the first AZ class and `FRC-` for the second)

| # | Check |
|---|---|
| 01 | PVC stays `Pending` without a pod (`WaitForFirstConsumer`) |
| 02 | Disk created when a pod uses it |
| 03 | PV pinned to the AZ |
| 04 | PV handle is an EVS disk ID |
| 05 | Pod ready with the disk attached and mounted |
| 06 | `VolumeAttachment` on the pod's node |
| 07 | `ext4` mounted at `/data` |
| 08 | About 10 GiB visible |
| 09 | Non-root container can write (`fsGroup`) |
| 10 | 256 MiB of random data written with a checksum |
| 11 | Pod recreated on the same node, data intact |
| 12 | Pod moved to another node in the AZ: detach, attach, data intact |
| 13, 14 | Online expansion to 20 GiB and 30 GiB while the pod runs, no restart |
| 15 | Data intact after expansion |
| 16 | Deleting the PVC deletes the disk and the attachment |

**Phase 5, Advanced**

| ID | Check |
|---|---|
| A01, A02 | XFS: provision, mount, online expansion to 15 GiB |
| A03, A04 | Raw block volume presented to the pod; 64 MiB direct write and read-back |
| A05, A06 | StatefulSet gets one disk per replica and reuses them after scaling to 0 and back |
| A07 | `ReadWriteMany` is not usable (expected warning) |
| A08 | A disk from one AZ cannot be used from a node in the other AZ |
| A09 | Snapshot CRDs, controller and classes present |
| A10 | Snapshot of a live volume becomes ready |
| A11 | Restore from the snapshot; data matches |
| A12 | Deleting the snapshot removes its content (with a `Delete` class) |

**Phase 6, Resilience**

| ID | Check |
|---|---|
| R01 | An app writes continuously to an EVS volume |
| R02, R03 | Node plugin on the app's node deleted: app I/O continues, plugin re-registers |
| R04, R05 | Active controller deleted: the standby takes all leases, provisioning still works |
| R06 | IAM stub deleted (passes as "not used") |
| R07 | Every controller pod deleted at once: controller back and ready |
| R08 | Deleting the app pod detaches its disk |
| R09 | Disk re-attached on the other node in the AZ, no data lost |

**Phase 7, Heavy load**

| ID | Check |
|---|---|
| L01, L02 | 20 PVCs at once, all bound; 20 pods, all ready |
| L03 | No provisioning or attach failure events during the burst |
| L04, L05 | 20 concurrent 512 MiB direct writes, then reads |
| L06 | All 20 checksums intact |
| L07, L08 | 4 KiB direct random I/O per AZ, queue depth 1 |
| L09 | Volumes per node within the published limit |
| L10 | Controller: no restarts, no call failed from throttling or 5xx; counts calls retried after 429 |
| L11, L12 | Deleting the 20 PVCs deletes all disks and attachments |

**Phase 8, Production readiness**

| ID | Check |
|---|---|
| PR01 | TLS verified (`ca-file`), not `insecure` |
| PR02 | Dedicated least-privilege service user (manual review) |
| PR03 | No IAM workaround |
| PR04 | `evs`/`ecs` names in DNS, not only host entries |
| PR05 | Driver build ownership (manual review) |
| PR06 | Driver image survives a registry restart |
| PR07 | Images pinned by digest |
| PR08 | Controller has more than one replica |
| PR09 | Resource requests on every container |
| PR10 | Priority classes on driver pods |
| PR11 | Snapshot class ready for backup tools |
| PR12 | Default StorageClass decided |
| PR13 | Monitoring and alerts for the driver |
| PR14 | Node plugin needs the host network (see N24) |
| PR15 | Phases 4 to 7: no failures |
| PR16 | Vendor support position (manual review) |
| PR17 | API rate limit enough for a burst: no call failed from throttling |

### 7.4 What counts as a pass

* **0 FAIL.** Any failure blocks go-live.
* **Every warning resolved or accepted, with an owner.** On HCS with OVN-Kubernetes these are expected:

| Warning | Meaning | Action |
|---|---|---|
| N24 / PR14 | Pods cannot reach the metadata service from the pod network | None needed; the node plugin uses the host network. Accept |
| A07 | A `ReadWriteMany` PVC binds but cannot be shared | Block `ReadWriteMany` on `evs-*` classes by policy |
| PR02 | Service user review | Confirm the access key belongs to a user with EVS and ECS rights only; rotate it on a schedule |
| PR04 | Names come from host entries | Ask the cloud operator for the two DNS records, then reinstall without `-GatewayIp` |
| PR05, PR16 | Fork build and vendor support | Record who owns the build until the upstream PR is merged, and the support position of the platform and cloud vendors |
| PR12 | No default StorageClass | Choose one `evs-<az>` class as default, or require classes to be named |
| PR13 | No alerts | Add the alerts in section 9.1 |

L03 can warn with `FailedAttachVolume: timed out waiting for external-attacher` when the burst outruns the API
pacing. Kubernetes retries those attaches, and L02 shows whether all 20 pods came up. With `api-burst=50` a 20-disk
burst normally goes out without waiting.

## 8. Reference results

The full suite on the environment in section 2, 12 Nov 2026, after a fresh install with this kit: 140 tests,
130 pass, 10 warnings, 0 failures. The warnings were the expected ones in section 7.4 and L03 (22 attach retries,
all recovered, from the earlier pacing default of burst 10).

| Measurement | Result |
|---|---|
| Disk created after the pod is scheduled | 5–6 s |
| Pod ready with a new disk | 19–25 s |
| Pod moved to another node, data intact | 29–40 s |
| Online expansion, per step | 63–89 s |
| Controller failover | 22 s |
| 20 disks at once | all bound and attached; 0 calls throttled |
| Sequential throughput, 20 volumes at once | about 400 MB/s write and 520 MB/s read per volume |
| 4 KiB random I/O at queue depth 1 | about 1,300–1,500 write and 3,500–4,000 read IOPS |
| Deleting 20 disks | 277 s |
| Volumes per node | limit 24 |

## 9. Operate

### 9.1 Monitoring

On OpenShift these metrics are in the platform monitoring stack. Alert on:

| Alert | Expression |
|---|---|
| Driver pod restarting | `increase(kube_pod_container_status_restarts_total{namespace="kube-system",pod=~"csi-evs-.*"}[15m]) > 0` |
| Controller down | `kube_deployment_status_replicas_available{namespace="kube-system",deployment="csi-evs-controller"} < 1` |
| Node plugin missing | `kube_daemonset_status_number_unavailable{namespace="kube-system",daemonset="csi-evs-plugin"} > 0` |
| Volume almost full | `kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.1` |

Also watch for `ProvisioningFailed`, `FailedAttachVolume` and `FailedMount` events, and for
`429 Too Many Requests, retry` lines in the controller log (`oc -n kube-system logs deploy/csi-evs-controller
-c evs-csi-provisioner`). A few retries under load are normal. Calls that still fail after the retries mean the
pacing or the API limit needs to change.

### 9.2 Using the storage

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: evs-az1
  resources: {requests: {storage: 50Gi}}
```

* Disks belong to one AZ. A pod using one is only scheduled to nodes in that AZ. Spread replicas across AZs with
  one claim per replica, not one shared claim.
* `ReadWriteOnce` only. Use `volumeMode: Block` for raw devices.
* Grow a volume by raising `spec.resources.requests.storage`; the filesystem grows while the pod runs.
  Volumes cannot shrink.
* Each node can attach up to the published limit (24 on the reference cluster).

### 9.3 Snapshots and backup

`evs-snap` is the snapshot class, labelled for Velero and OADP. Its deletion policy is `Retain`: deleting a
`VolumeSnapshot` keeps the snapshot in HCS, so backups survive a mistaken delete. Clean up retained snapshots in
the EVS console or by deleting their `VolumeSnapshotContent` after changing its policy. Restore by creating a PVC
with `dataSource` pointing at the snapshot, in the same AZ class.

### 9.4 Changes

Every change reruns the installer with the same options as the install plus the change. Rewriting the Secret
restarts the driver pods, which pauses attach and detach for about a minute. Running pods keep their disks.

| Change | How |
|---|---|
| Rotate the access key | New `credentials.csv` from the cloud console, then rerun with `-CredentialsCsv` |
| New CA, or the operator renews the root | Rerun with `-FetchCa` and the new `-CaFingerprint`, or `-CaFile` |
| API pacing | Rerun with `-ApiRateLimit` / `-ApiBurst` and `-CredentialsCsv` (the values live in the Secret) |
| Upgrade the driver | Resolve the new digest (section 5.2), run phases 1–3 and 4 on a test cluster, then rerun with the new `-Image` and `-KeepSecret` |
| Roll back the driver | Rerun with the previous `-Image` digest and `-KeepSecret` |
| Add an AZ | Rerun with the new AZ added to `-VolumeTypes` |
| Move to the upstream release | When the PR is merged and Huawei publishes an image, rerun with that image; `cloud-config` stays the same |

After each change, run `./test.ps1 -Phases 1,2,3`.

### 9.5 Uninstall

```bash
pwsh ./install.ps1 -Cloud cloud.example.com -Region xx-xxxx-1 -ProjectId <project id> -Uninstall
```

This removes the driver and leaves the Secret, StorageClasses, PVCs, PVs and the disks in HCS. While the driver
is absent, no disk can be attached, detached, created or deleted. Delete PVCs before uninstalling if the disks
should go too.

## 10. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `x509: certificate signed by unknown authority` in the controller log | CA not trusted, or `insecure=false` without `ca-file` | Rerun the install with `-FetchCa` and `-CaFingerprint`, or `-CaFile` |
| `dial tcp: lookup evs.<region>.<cloud>: no such host` | No DNS record | Add the records, or reinstall with `-GatewayIp` |
| Driver exits at start after calling `/v3/auth/catalog` | `skip-catalog` missing | Install with `-Hcs` |
| Create fails with `EVS.1021`, attach with `Ecs.0005`, or `APIGW.0101` on expand or snapshot | Driver not in HCS mode, or an image without the HCS changes | Install with `-Hcs` and the fork image |
| `APIGW.0308` / `429 Too Many Requests, retry n/8` | Per-user API limit reached | Retries handle short bursts. If calls still fail, lower `-ApiRateLimit` or ask for a higher limit |
| PVC `Pending`, "waiting for first consumer" | Normal until a pod uses it | None |
| Pod `Pending`, "didn't match PersistentVolume's node affinity" | Pod can only run in the disk's AZ and no node there fits | Free capacity in that AZ |
| `FailedAttachVolume: timed out waiting for external-attacher` during a burst | Attaches queued behind API pacing | They retry; check that the pods start. Raise `-ApiBurst` within the limit |
| `Multi-Attach error` after a node failure | Disk still attached to the failed node | Once the node is confirmed down, add the `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` taint so Kubernetes detaches its disks; remove the taint when the node is back |
| Node plugin cannot get its AZ | Metadata service not reachable | The node plugin must stay on the host network (the kit's default); check the route to `169.254.169.254` |

Logs:

```bash
oc -n kube-system logs deploy/csi-evs-controller -c evs-csi-provisioner     # driver, controller side
oc -n kube-system logs ds/csi-evs-plugin -c evs-csi-plugin                    # driver, one node
oc -n kube-system logs deploy/csi-evs-controller -c csi-attacher              # attach and detach
```

## 11. Known limits

* `ReadWriteOnce` and block volumes only; no shared disks.
* Disks cannot leave their AZ.
* The node plugin needs privileged mode and the host network.
* 200 API calls per 5 minutes per user on HCS by default.
* Snapshots are retained in HCS after the Kubernetes object is deleted (class `evs-snap`).
* The driver is a fork build until the upstream PR is merged.

## 12. Sign-off

| Item | Done |
|---|---|
| Service user with EVS and ECS rights only; key stored only in the cluster Secret | |
| Root CA fingerprint confirmed with the cloud operator; PR01 passes | |
| DNS records for `evs` and `ecs`, or `-GatewayIp` accepted | |
| Driver image pinned by digest and stored outside the cluster's own EVS-backed registry | |
| Full suite: 0 failures, warnings resolved or accepted with owners | |
| Default StorageClass decided; `ReadWriteMany` blocked on `evs-*` | |
| Alerts from section 9.1 in place | |
| Backup tested with `evs-snap` | |
| Key rotation date set | |
