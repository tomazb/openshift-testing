# network-testing-image

UBI9-based container image with networking, storage, and troubleshooting tools.
Used as the pod image by the `network-validation` tool and available as a
standalone debug image for OpenShift clusters.

## Registry

```
ghcr.io/tomazb/openshift-testing/network-testing-image
```

| Tag | When published |
|-----|---------------|
| `latest` | Every push to `main` |
| `main` | Every push to `main` |
| `sha-<short-sha>` | Every push |
| `network-testing-image-v*` | Version tags |

Builds for **linux/amd64** and **linux/arm64**.

## Tools

### Network testing
| Tool | Source |
|------|--------|
| iperf3 3.21 | Built from source |
| netperf | EPEL9 |
| qperf | EPEL9 |
| fio 3.42 | Built from source |

### Network utilities
| Tool | Source |
|------|--------|
| tcpdump | UBI9 |
| iproute (`ip`, `ss`) | UBI9 |
| iputils (`ping`, `arping`, `tracepath`) | UBI9 |
| mtr | UBI9 |
| nmap / ncat | UBI9 |
| ethtool | UBI9 |
| bind-utils (`dig`, `host`, `nslookup`) | UBI9 |
| httpd-tools (`ab`) | UBI9 |

### Storage
| Tool | Source |
|------|--------|
| lvm2 (`lvs`, `pvs`, `vgs`) | UBI9 |
| sg3_utils (`sg_map`, `sg_inq`) | UBI9 |
| s3fs-fuse | EPEL9 |
| rclone v1.73.5 | Downloaded binary (sha256 verified) |

### Kubernetes / OpenShift
| Tool | Source |
|------|--------|
| oc / kubectl 4.19.12 | Downloaded binary (sha256 verified) |

### Utilities
| Tool | Source |
|------|--------|
| step-cli 0.30.2 | Downloaded binary (sha256 verified) |
| jq | UBI9 |
| yq v4.53.2 | Downloaded binary (sha256 verified) |
| rsync | UBI9 |
| wget | UBI9 |
| curl (curl-minimal) | UBI9 base |

### Not included
`whois` and `wireshark-cli`/`tshark` are intentionally absent — they are not
available in the configured UBI9 and EPEL9 repositories.

## Usage

### Quick debug pod on OpenShift

```bash
oc run nettest --image=ghcr.io/tomazb/openshift-testing/network-testing-image \
  --restart=Never --rm -it -- bash
```

### Debug pod on a specific node

```bash
oc debug node/<node-name> --image=ghcr.io/tomazb/openshift-testing/network-testing-image
```

### Run as a DaemonSet (host-network)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nettest
spec:
  selector:
    matchLabels:
      app: nettest
  template:
    metadata:
      labels:
        app: nettest
    spec:
      hostNetwork: true
      containers:
      - name: nettest
        image: ghcr.io/tomazb/openshift-testing/network-testing-image
        command: ["sleep", "infinity"]
```

## Building

```bash
podman build -f network-testing-image/Containerfile -t network-testing-image .
```

The build context must be the repository root (`.`) because the `Containerfile`
uses a multi-stage build.

Override a tool version at build time:

```bash
podman build -f network-testing-image/Containerfile \
  --build-arg IPERF3_VERSION=3.21 \
  --build-arg IPERF3_SHA256=656e4405ebd620121de7ceca3eaf43a88f79ea1b857d041a6a0b1314801acdd8 \
  -t network-testing-image .
```

Available `--build-arg` overrides:

| ARG | Default |
|-----|---------|
| `IPERF3_VERSION` | `3.21` |
| `IPERF3_SHA256` | *(see Containerfile)* |
| `FIO_VERSION` | `3.42` |
| `FIO_SHA256` | *(see Containerfile)* |
| `RCLONE_VERSION` | `v1.73.5` |
| `OPENSHIFT_CLIENT_VERSION` | `4.19.12` |
| `STEP_CLI_VERSION` | `0.30.2` |
| `YQ_VERSION` | `v4.53.2` |

## Supply chain

- The UBI9 base image is pinned to a specific version tag (not `:latest`).
- All downloaded binaries are verified with SHA256 checksums before installation.
- `iperf3` and `fio` are compiled from pinned, checksum-verified source tarballs
  in a separate builder stage; no build tools are present in the final image.
- Build provenance attestation is generated for every push via
  `actions/attest-build-provenance`.
