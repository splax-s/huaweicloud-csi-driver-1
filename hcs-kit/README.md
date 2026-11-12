# EVS CSI install and test kit

Installs the EVS CSI driver on OpenShift or Kubernetes, on Huawei Cloud Stack (HCS) or Huawei Cloud, and runs
the validation suite against it. Nothing here is specific to one site: every value is a parameter.

Needs PowerShell (7 on macOS/Linux, 5.1 or 7 on Windows) and `oc` or `kubectl` logged in as cluster-admin.

## 1. Collect

| Value | Example | Where |
|---|---|---|
| Cloud domain | `cloud.example.com` | HCS console URL without the service prefix |
| Region | `xx-xxxx-1` | console, top left |
| Project ID | 32 hex characters | My Credentials, Projects (the resource space's project) |
| Access key | `credentials.csv` | My Credentials, Access Keys, for a user limited to EVS and ECS |
| AZ and volume type per AZ | `az1=type_01` | EVS console, Create Disk |
| API gateway IP | `xx.xx.xx.xx` | only if `evs.<region>.<cloud>` does not resolve in the cluster |
| Root CA fingerprint | `AB:CD:…` (SHA-256) | your cloud operator (HCS ships with its own CA) |

## 2. Install

```bash
pwsh ./install.ps1 -Cloud cloud.example.com -Region xx-xxxx-1 -ProjectId <id> -CredentialsCsv ./credentials.csv \
  -Hcs -VolumeTypes 'az1=type_01,az2=type_02' -Image <registry>/evs-csi-plugin@sha256:<digest> \
  -GatewayIp xx.xx.xx.xx -FetchCa xx.xx.xx.xx
```

The first run with `-FetchCa` prints the root CA it was sent and stops. Check the fingerprint with your cloud
operator, then run again with `-CaFingerprint <value>`. With a CA file use `-CaFile ./ca.crt` instead; on Huawei
Cloud, where the API certificates are public, leave out all three. `-Insecure` turns TLS verification off.

What it sets up:

* `kube-system/cloud-config`: the access key (never printed), `hcs` and `skip-catalog` with `-Hcs`, the CA, and
  `api-rate-limit=0.5` and `api-burst=50` with `-Hcs`. HCS limits each user to 200 API calls per 5 minutes;
  50 + 0.5 × 300 s is exactly 200, so a pod never goes over it on its own, and a burst of 20 disks goes out
  without waiting. The driver also retries any call the gateway still rejects with 429. Change them with
  `-ApiRateLimit` and `-ApiBurst`; `-ApiRateLimit 0` turns pacing off and leaves only the retries.

Running the cluster in production: see [PRODUCTION.md](PRODUCTION.md).
* One StorageClass `evs-<az>` per AZ: WaitForFirstConsumer, expandable, pinned to its AZ.
* The driver, from `manifests/base` plus a generated overlay (image, gateway hosts) in `manifests/generated`.
* `kube-system/evs-csi-install`: the settings above without the key, for `test.ps1`.

`-DryRun` renders and checks everything without changing the cluster. `-Uninstall` removes the driver and leaves
the secret, the StorageClasses, the volumes and the disks. Snapshots need the `snapshot.storage.k8s.io` CRDs and a
snapshot controller: OpenShift has them, plain Kubernetes needs the external-snapshotter installed.

## 3. Test

```bash
pwsh ./test.ps1                 # all 8 phases, about 35 minutes
pwsh ./test.ps1 -Phases 1,2,3   # platform, network and topology checks only, a few minutes
```

Phases 4 to 7 create and delete real disks: per AZ, then across AZs, failover, and a burst of 10 disks per AZ.
Phase 8 lists what to settle before production. One AZ works too; the cross-AZ and node-move tests then report a
warning. Results are written to `results-<time>/` (`summary.txt`, `suite.log`, `suite-results.jsonl`).
