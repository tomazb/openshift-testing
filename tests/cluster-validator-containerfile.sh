#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINERFILE="$REPO_ROOT/cluster-validator/Containerfile"

if [[ ! -f "$CONTAINERFILE" ]]; then
  echo "missing cluster-validator Containerfile" >&2
  exit 1
fi

grep -Fq "COPY dns-validation/" "$CONTAINERFILE"
grep -Fq "COPY network-validation/" "$CONTAINERFILE"
grep -Fq "COPY cluster-validator/bin/entrypoint.sh /usr/local/bin/validator" "$CONTAINERFILE"
grep -Fq "chgrp -R 0 /artifacts /config /tmp/validator-home" "$CONTAINERFILE"
grep -Fq "chmod -R g=u /artifacts /config /tmp/validator-home" "$CONTAINERFILE"
grep -Fxq "ENV HOME=/tmp/validator-home" "$CONTAINERFILE"
grep -Fxq "USER 1001" "$CONTAINERFILE"
grep -Fxq 'ENTRYPOINT ["/usr/local/bin/validator"]' "$CONTAINERFILE"

for entrypoint in \
  "$REPO_ROOT/dns-validation/bin/ocp-dns-validate" \
  "$REPO_ROOT/network-validation/bin/ocp-network-validate" \
  "$REPO_ROOT/cluster-validator/bin/entrypoint.sh"; do
  if [[ ! -x "$entrypoint" ]]; then
    echo "cluster-validator image entrypoint dependency must be executable: $entrypoint" >&2
    exit 1
  fi
done
