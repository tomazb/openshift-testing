# Minimal dnsperf helper image for OpenShift DNS validation.
#
# Build with:
#   podman build -t registry.example.com/tools/dnsperf:2.x -f dns-validation/containerfiles/dnsperf.Containerfile .
#   podman push registry.example.com/tools/dnsperf:2.x
#
# Important:
#   dnsperf packaging availability differs by base image/repository policy.
#   For customer or regulated environments, prefer an internally approved,
#   pinned dnsperf image and set DNSPERF_IMAGE in config/validation.env.

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf -y install bind-utils procps-ng && \
    microdnf clean all

# This base intentionally does not assume a public dnsperf RPM source.
# Extend it with an approved dnsperf binary/package source if you need
# a locally built image.

USER 1001
CMD ["/bin/sh", "-c", "sleep 3600"]
