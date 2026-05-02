# Network Testing Image Toolbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand the UBI9 network-testing image into a broader OpenShift, Kubernetes, network, object-storage, and storage-performance diagnostics toolbox.

**Architecture:** Keep the single `network-testing-image/Containerfile` as the build contract. Use UBI/RHEL packages for repository-provided tools, keep external binaries pinned and checksum-verified, and extend the existing GitHub Actions smoke test to prove command availability, version pins, and completion files.

**Follow-up sourcing update, 2026-05-01:** EPEL9 is approved for this image. Verification against the actual UBI9 build environment showed EPEL9 provides `netperf`, `qperf`, and `s3fs-fuse`, but not `fio`, `whois`, or `wireshark-cli`/`tshark`. The implementation should therefore install the available EPEL packages, source-build `fio` from the official release tarball with a pinned SHA-256, and continue deferring `whois` and `tshark`.

**Tech Stack:** UBI9, Bash, Docker/Buildx, GitHub Actions, shell-based static tests.

---

## File Structure

- Modify `network-testing-image/Containerfile`: package additions, pinned external client installs, generated bash completions.
- Modify `.github/workflows/network-testing-image.yml`: expanded smoke test command list, version checks, completion checks.
- Modify `tests/network-testing-image-containerfile.sh`: static assertions for packages, version pins, checksum verification, and completion generation.
- Modify `tests/network-testing-image-workflow.sh`: static assertions that CI checks the expanded toolbox.
- Modify `README.md`: document the expanded toolbox and runtime permission caveats.

## External Version Pins

Use these pins for the first implementation pass:

- `RCLONE_VERSION=v1.73.5` from the existing image.
- `OPENSHIFT_CLIENT_VERSION=4.19.12`, using the official OpenShift client mirror archive and `sha256sum.txt`.
- `STEP_CLI_VERSION=0.30.2`, using the official smallstep release and `checksums.txt`.
- `YQ_VERSION=v4.53.2`, using the official mikefarah/yq release and `checksums-bsd`.
- `FIO_VERSION=3.42`, using the official fio release tarball from `https://brick.kernel.dk/snaps/` and a pinned SHA-256.

Use EPEL only for requested tools verified to be available in EPEL9 on UBI9. If a requested package is unavailable from the configured UBI and EPEL repositories, stop and use `superpowers:systematic-debugging` to confirm the missing package before changing scope.

### Task 1: Add Failing Static Tests

**Files:**
- Modify: `tests/network-testing-image-containerfile.sh`
- Modify: `tests/network-testing-image-workflow.sh`

- [ ] **Step 1: Extend the Containerfile static test**

Add this block after the existing `grep -Eq '^[[:space:]]+unzip[[:space:]]+\\$' "$CONTAINERFILE"` assertion in `tests/network-testing-image-containerfile.sh`:

```bash
for package in \
  bash-completion \
  bind-utils \
  httpd-tools \
  jq \
  nmap \
  ethtool \
  netperf \
  qperf \
  s3fs-fuse; do
  if ! grep -Eq "^[[:space:]]+${package}[[:space:]]+\\\\$" "$CONTAINERFILE"; then
    echo "missing expected package in Containerfile: $package" >&2
    exit 1
  fi
done

grep -Fxq "ARG OPENSHIFT_CLIENT_VERSION=4.19.12" "$CONTAINERFILE"
grep -Fxq "ARG STEP_CLI_VERSION=0.30.2" "$CONTAINERFILE"
grep -Fxq "ARG YQ_VERSION=v4.53.2" "$CONTAINERFILE"
grep -Fxq "ARG FIO_VERSION=3.42" "$CONTAINERFILE"
grep -Fxq "ARG FIO_SHA256=9128d0c81bd7bffab0dd06cbfb755a05ef92f3b8a0b0c61f1b3538df6750f1e0" "$CONTAINERFILE"

grep -Fq 'openshift-client-linux-${OC_ARCH}-rhel9-${OPENSHIFT_CLIENT_VERSION}.tar.gz' "$CONTAINERFILE"
grep -Fq 'https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_CLIENT_VERSION}' "$CONTAINERFILE"
grep -Fq 'https://github.com/smallstep/cli/releases/download/v${STEP_CLI_VERSION}' "$CONTAINERFILE"
grep -Fq 'https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}' "$CONTAINERFILE"
grep -Fq 'https://brick.kernel.dk/snaps/${FIO_TARBALL}' "$CONTAINERFILE"

for completion in oc kubectl rclone step yq; do
  grep -Fq "/etc/bash_completion.d/$completion" "$CONTAINERFILE"
done
```

- [ ] **Step 2: Extend the workflow static test**

Replace the existing command-list assertion in `tests/network-testing-image-workflow.sh`:

```bash
grep -Fq "for cmd in tcpdump ip ss ping tracepath mtr iperf3 rsync curl wget unzip lvs sg_map rclone; do" "$WORKFLOW"
```

with:

```bash
grep -Fq "for cmd in tcpdump ip ss ping tracepath mtr dig host nslookup iperf3 rsync curl wget unzip lvs sg_map rclone oc kubectl ab step jq yq nmap ncat ethtool arping netperf qperf s3fs fio; do" "$WORKFLOW"
grep -Fq 'for unavailable_cmd in whois tshark; do' "$WORKFLOW"
grep -Fq 'for completion in oc kubectl rclone step yq; do' "$WORKFLOW"
grep -Fq 'test -s "/etc/bash_completion.d/$completion"' "$WORKFLOW"
grep -Fq 'oc version --client' "$WORKFLOW"
grep -Fq 'kubectl version --client=true' "$WORKFLOW"
grep -Fq 'step version' "$WORKFLOW"
grep -Fq 'yq --version' "$WORKFLOW"
```

- [ ] **Step 3: Run the focused tests and verify they fail**

Run:

```bash
bash tests/network-testing-image-containerfile.sh
```

Expected: FAIL with `missing expected package in Containerfile: bash-completion`.

Run:

```bash
bash tests/network-testing-image-workflow.sh
```

Expected: FAIL because the workflow still has the old command list and no completion/version checks.

### Task 2: Expand the Containerfile

**Files:**
- Modify: `network-testing-image/Containerfile`
- Test: `tests/network-testing-image-containerfile.sh`

- [ ] **Step 1: Replace the Containerfile with the expanded toolbox build**

Replace `network-testing-image/Containerfile` with:

```Dockerfile
FROM registry.access.redhat.com/ubi9/ubi:9.7 AS fio-builder

ARG FIO_VERSION=3.42
ARG FIO_SHA256=9128d0c81bd7bffab0dd06cbfb755a05ef92f3b8a0b0c61f1b3538df6750f1e0

RUN dnf install -y \
    gcc \
    make \
    zlib-devel \
    libaio-devel \
    tar \
    gzip \
    && dnf clean all

RUN set -eux; \
    FIO_TARBALL="fio-${FIO_VERSION}.tar.gz"; \
    curl -fsSLo "${FIO_TARBALL}" "https://brick.kernel.dk/snaps/${FIO_TARBALL}"; \
    echo "${FIO_SHA256}  ${FIO_TARBALL}" | sha256sum -c -; \
    mkdir -p /tmp/fio-src; \
    tar -xzf "${FIO_TARBALL}" -C /tmp/fio-src --strip-components=1; \
    cd /tmp/fio-src; \
    ./configure --prefix=/usr/local --disable-native; \
    make -j"$(nproc)"; \
    make install DESTDIR=/tmp/fio-out; \
    /tmp/fio-out/usr/local/bin/fio --version | grep -F "fio-${FIO_VERSION}"

FROM registry.access.redhat.com/ubi9/ubi:9.7

LABEL org.opencontainers.image.source="https://github.com/tomazb/openshift-testing" \
      org.opencontainers.image.description="OpenShift network and storage testing helper image"

ARG RCLONE_VERSION=v1.73.5
ARG OPENSHIFT_CLIENT_VERSION=4.19.12
ARG STEP_CLI_VERSION=0.30.2
ARG YQ_VERSION=v4.53.2
ARG EPEL_RELEASE_URL=https://dl.fedoraproject.org/pub/epel/9/Everything/x86_64/Packages/e/epel-release-9-10.el9.noarch.rpm
ARG TARGETARCH

# whois and wireshark-cli/tshark remain deferred because they are unavailable
# in configured UBI9 and EPEL9 repositories.
RUN dnf install -y \
    bash-completion \
    tcpdump \
    iproute \
    iputils \
    mtr \
    iperf3 \
    rsync \
    wget \
    unzip \
    tar \
    gzip \
    lvm2 \
    sg3_utils \
    bind-utils \
    httpd-tools \
    jq \
    nmap \
    ethtool \
    && dnf clean all

RUN dnf install -y "${EPEL_RELEASE_URL}" \
    && dnf install -y \
    netperf \
    qperf \
    s3fs-fuse \
    && dnf clean all

COPY --from=fio-builder /tmp/fio-out/usr/local/bin/fio /usr/local/bin/fio

RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
        amd64|x86_64) RCLONE_ARCH="amd64" ;; \
        arm64|aarch64) RCLONE_ARCH="arm64" ;; \
        *) echo "Unsupported architecture for rclone: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    RCLONE_ZIP="rclone-${RCLONE_VERSION}-linux-${RCLONE_ARCH}.zip"; \
    curl -fsSLO "https://downloads.rclone.org/${RCLONE_VERSION}/${RCLONE_ZIP}"; \
    curl -fsSLO "https://downloads.rclone.org/${RCLONE_VERSION}/SHA256SUMS"; \
    grep "  ${RCLONE_ZIP}$" SHA256SUMS > rclone.sha256; \
    sha256sum -c --ignore-missing rclone.sha256; \
    unzip -q "${RCLONE_ZIP}"; \
    cp "rclone-${RCLONE_VERSION}-linux-${RCLONE_ARCH}/rclone" /usr/local/bin/rclone; \
    chmod 755 /usr/local/bin/rclone; \
    rm -rf "${RCLONE_ZIP}" SHA256SUMS rclone.sha256 "rclone-${RCLONE_VERSION}-linux-${RCLONE_ARCH}"

RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
        amd64|x86_64) OC_ARCH="amd64" ;; \
        arm64|aarch64) OC_ARCH="arm64" ;; \
        *) echo "Unsupported architecture for OpenShift client: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    OC_BASE_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_CLIENT_VERSION}"; \
    OC_TARBALL="openshift-client-linux-${OC_ARCH}-rhel9-${OPENSHIFT_CLIENT_VERSION}.tar.gz"; \
    curl -fsSLO "${OC_BASE_URL}/${OC_TARBALL}"; \
    curl -fsSLO "${OC_BASE_URL}/sha256sum.txt"; \
    grep "  ${OC_TARBALL}$" sha256sum.txt > oc.sha256; \
    sha256sum -c --ignore-missing oc.sha256; \
    tar -xzf "${OC_TARBALL}" oc kubectl; \
    install -m 0755 oc kubectl /usr/local/bin/; \
    rm -f "${OC_TARBALL}" sha256sum.txt oc.sha256 oc kubectl README.md

RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
        amd64|x86_64) STEP_ARCH="amd64" ;; \
        arm64|aarch64) STEP_ARCH="arm64" ;; \
        *) echo "Unsupported architecture for step-cli: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    STEP_TARBALL="step_linux_${STEP_CLI_VERSION}_${STEP_ARCH}.tar.gz"; \
    STEP_BASE_URL="https://github.com/smallstep/cli/releases/download/v${STEP_CLI_VERSION}"; \
    curl -fsSL -O "${STEP_BASE_URL}/${STEP_TARBALL}"; \\
    curl -fsSL -O "${STEP_BASE_URL}/checksums.txt"; \
    grep "  ${STEP_TARBALL}$" checksums.txt > step.sha256; \
    sha256sum -c --ignore-missing step.sha256; \
    tar -xzf "${STEP_TARBALL}"; \
    install -m 0755 "step_${STEP_CLI_VERSION}/bin/step" /usr/local/bin/step; \
    rm -rf "${STEP_TARBALL}" checksums.txt step.sha256 "step_${STEP_CLI_VERSION}"

RUN set -eux; \
    case "${TARGETARCH:-$(uname -m)}" in \
        amd64|x86_64) YQ_ARCH="amd64" ;; \
        arm64|aarch64) YQ_ARCH="arm64" ;; \
        *) echo "Unsupported architecture for yq: ${TARGETARCH:-$(uname -m)}" >&2; exit 1 ;; \
    esac; \
    YQ_BINARY="yq_linux_${YQ_ARCH}"; \
    YQ_TARBALL="${YQ_BINARY}.tar.gz"; \
    YQ_BASE_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}"; \
    curl -fsSL -O "${YQ_BASE_URL}/${YQ_TARBALL}"; \\
    curl -fsSL -O "${YQ_BASE_URL}/checksums-bsd"; \\
    grep "SHA256 (${YQ_TARBALL})" checksums-bsd | sed 's/.*) = //; t; d' | awk -v file="${YQ_TARBALL}" '{ print $1 "  " file }' > yq.sha256; \
    test -s yq.sha256; \
    sha256sum -c yq.sha256; \
    tar -xzf "${YQ_TARBALL}"; \
    install -m 0755 "./${YQ_BINARY}" /usr/local/bin/yq; \
    rm -f "${YQ_TARBALL}" checksums-bsd yq.sha256 "${YQ_BINARY}" yq.1 install-man-page.sh

RUN set -eux; \
    mkdir -p /etc/bash_completion.d; \
    rclone genautocomplete bash /etc/bash_completion.d/rclone; \
    oc completion bash > /etc/bash_completion.d/oc; \
    kubectl completion bash > /etc/bash_completion.d/kubectl; \
    step completion bash > /etc/bash_completion.d/step; \
    yq shell-completion bash > /etc/bash_completion.d/yq; \
    chmod 0644 /etc/bash_completion.d/oc /etc/bash_completion.d/kubectl /etc/bash_completion.d/rclone /etc/bash_completion.d/step /etc/bash_completion.d/yq; \
    printf '%s\n' \
      'if [ -f /etc/profile.d/bash_completion.sh ]; then' \
      '  . /etc/profile.d/bash_completion.sh' \
      'fi' \
      > /etc/profile.d/network-testing-completion.sh; \
    chmod 0644 /etc/profile.d/network-testing-completion.sh

CMD ["/bin/bash"]
```

- [ ] **Step 2: Run the Containerfile static test**

Run:

```bash
bash tests/network-testing-image-containerfile.sh
```

Expected: PASS with no output.

- [ ] **Step 3: Commit the Containerfile and static test**

Run:

```bash
git add network-testing-image/Containerfile tests/network-testing-image-containerfile.sh
git commit -m "Expand network testing image toolbox"
```

Expected: commit succeeds and includes only those two files.

### Task 3: Extend the CI Smoke Test

**Files:**
- Modify: `.github/workflows/network-testing-image.yml`
- Test: `tests/network-testing-image-workflow.sh`

- [ ] **Step 1: Replace the smoke-test command block**

In `.github/workflows/network-testing-image.yml`, replace the `Smoke test image` inline script with:

```yaml
          docker run --rm network-testing-image:test bash -euxo pipefail -c '
            for cmd in tcpdump ip ss ping tracepath mtr dig host nslookup iperf3 rsync curl wget unzip lvs sg_map rclone oc kubectl ab step jq yq nmap ncat ethtool arping netperf qperf s3fs fio; do
              command -v "$cmd"
            done
            for unavailable_cmd in whois tshark; do
              if command -v "$unavailable_cmd"; then
                echo "deferred tool unexpectedly installed: $unavailable_cmd" >&2
                exit 1
              fi
            done
            for completion in oc kubectl rclone step yq; do
              test -s "/etc/bash_completion.d/$completion"
            done
            test -s /etc/profile.d/network-testing-completion.sh
            source /etc/profile.d/network-testing-completion.sh
            test "$(rclone version | awk "NR == 1 { print \$2 }")" = "v1.73.5"
            oc version --client | grep -F "Client Version: 4.19.12"
            kubectl version --client=true
            step version | grep -F "0.30.2"
            yq --version | grep -F "v4.53.2"
            fio --version | grep -F "fio-3.42"
            fio --name=smoke --filename=/tmp/fio-smoke --size=4m --rw=readwrite --bs=4k --iodepth=1 --numjobs=1 --runtime=1 --time_based --group_reporting
          '
```

- [ ] **Step 2: Run the workflow static test**

Run:

```bash
bash tests/network-testing-image-workflow.sh
```

Expected: PASS with no output.

- [ ] **Step 3: Commit the workflow and workflow test**

Run:

```bash
git add .github/workflows/network-testing-image.yml tests/network-testing-image-workflow.sh
git commit -m "Smoke test network toolbox tools"
```

Expected: commit succeeds and includes only those two files.

### Task 4: Document the Expanded Toolbox

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the network image description paragraph**

In `README.md`, replace:

```markdown
The `network-testing-image/` directory defines a UBI9-based troubleshooting image with network and storage test tools. GitHub Actions builds and smoke-tests it on pull requests, then publishes it to GitHub Container Registry after changes land on `main`.
```

with:

```markdown
The `network-testing-image/` directory defines a UBI9-based troubleshooting image with OpenShift and Kubernetes clients, bash completion, DNS tools, packet and route inspection tools, throughput benchmarks, transfer utilities, S3-compatible storage helpers, and storage performance tooling. GitHub Actions builds and smoke-tests it on pull requests, then publishes it to GitHub Container Registry after changes land on `main`.
```

- [ ] **Step 2: Add runtime caveats after the published tags paragraph**

After:

```markdown
Published tags include `latest`, `main`, `sha-<commit>`, and `network-testing-image-v*` release tags.
```

add:

```markdown
Some tools need extra pod permissions to be useful. Packet capture, low-level interface inspection, and S3 FUSE mounts may require capabilities, device access, privileged security context settings, or cluster policy changes outside the image itself.
```

- [ ] **Step 3: Run static checks**

Run:

```bash
./scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 4: Commit README changes**

Run:

```bash
git add README.md
git commit -m "Document network toolbox image"
```

Expected: commit succeeds and includes only `README.md`.

### Task 5: Build and Verify the Image Locally

**Files:**
- Verify: `network-testing-image/Containerfile`
- Verify: `.github/workflows/network-testing-image.yml`

- [ ] **Step 1: Build the amd64 smoke-test image**

Run:

```bash
docker buildx build --load --platform linux/amd64 -f network-testing-image/Containerfile -t network-testing-image:toolbox-test .
```

Expected: PASS. If the build fails while resolving a package, read the package error exactly and use `superpowers:systematic-debugging` before changing package sources.

- [ ] **Step 2: Run the same smoke-test logic locally**

Run:

```bash
docker run --rm network-testing-image:toolbox-test bash -euxo pipefail -c '
  for cmd in tcpdump ip ss ping tracepath mtr dig host nslookup iperf3 rsync curl wget unzip lvs sg_map rclone oc kubectl ab step jq yq nmap ncat ethtool arping netperf qperf s3fs fio; do
    command -v "$cmd"
  done
  for unavailable_cmd in whois tshark; do
    if command -v "$unavailable_cmd"; then
      echo "deferred tool unexpectedly installed: $unavailable_cmd" >&2
      exit 1
    fi
  done
  for completion in oc kubectl rclone step yq; do
    test -s "/etc/bash_completion.d/$completion"
  done
  test -s /etc/profile.d/network-testing-completion.sh
  source /etc/profile.d/network-testing-completion.sh
  test "$(rclone version | awk "NR == 1 { print \$2 }")" = "v1.73.5"
  oc version --client | grep -F "Client Version: 4.19.12"
  kubectl version --client=true
  step version | grep -F "0.30.2"
  yq --version | grep -F "v4.53.2"
  fio --version | grep -F "fio-3.42"
  fio --name=smoke --filename=/tmp/fio-smoke --size=4m --rw=readwrite --bs=4k --iodepth=1 --numjobs=1 --runtime=1 --time_based --group_reporting
'
```

Expected: PASS.

- [ ] **Step 3: Run all repository static checks**

Run:

```bash
./scripts/check-static.sh
```

Expected: PASS.

- [ ] **Step 4: Commit verification fixes only if needed**

If verification required edits, commit them:

```bash
git add network-testing-image/Containerfile .github/workflows/network-testing-image.yml tests/network-testing-image-containerfile.sh tests/network-testing-image-workflow.sh README.md
git commit -m "Fix network toolbox verification"
```

Expected: either no commit is needed because the prior tasks already pass, or this commit contains only verification-driven fixes.

### Task 6: Final Review

**Files:**
- Review: `network-testing-image/Containerfile`
- Review: `.github/workflows/network-testing-image.yml`
- Review: `tests/network-testing-image-containerfile.sh`
- Review: `tests/network-testing-image-workflow.sh`
- Review: `README.md`

- [ ] **Step 1: Inspect final branch status**

Run:

```bash
git status --short
```

Expected: only unrelated pre-existing untracked files remain, or the worktree is clean.

- [ ] **Step 2: Inspect commits for this feature**

Run:

```bash
git --no-pager log --oneline -n 6
```

Expected: the branch contains the design commit plus implementation commits for tests, image changes, smoke tests, and documentation.

- [ ] **Step 3: Summarize deferred tools if any**

If every requested tool is installed, report that nothing was deferred.

If a tool was deferred because the package source failed the sourcing policy, report the exact tool name, the failed source, and the reason it was not added. Do not silently omit requested tools.
