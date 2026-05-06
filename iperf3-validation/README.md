# OpenShift iperf3 validation

`iperf3-validation/` runs a selected CoreOS node-to-node iperf3 test from OpenShift pods and stores comparable artifacts under a timestamped run directory.

Copy the example config, set the server and client node names, then run:

```bash
bash bin/ocp-iperf3-validate --config config/validation.env all
```

The first version targets one explicit node pair. TCP is the default profile. UDP can be enabled with `IPERF3_PROTOCOL=udp`, `IPERF3_BANDWIDTH`, and optional `IPERF3_PACKET_SIZE`; `auto` derives payload size from the interface MTU.

The harness discovers the server node `InternalIP` during preflight and passes it to the client pod. Set `IPERF3_SERVER_ADDRESS` only when the node IP should be overridden.

`IPERF3_PRIVILEGED_MODE=true` uses host networking, host PID visibility, and privileged containers so CoreOS host counters such as `/proc/interrupts`, `/sys/class/net`, and `ethtool` output are meaningful. Set it to `false` for restricted clusters; the collector will still run but records best-effort pod-visible diagnostics.

The report fails only for setup failures, iperf failures, missing artifacts, or configured threshold failures such as `IPERF3_MIN_TCP_GBPS` and `IPERF3_MAX_UDP_LOSS_PERCENT`.
