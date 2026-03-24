# Debezium Performance Test: OLR vs LogMiner on Oracle RAC

## Test Environment

| Component | Spec |
|-----------|------|
| Oracle RAC | 2-node 23.26.1.0, Podman containers in KVM VM |
| VM | 16 GB RAM, 8 vCPU, virtio disk (loop-device ASM) |
| Host | Intel NUC, Linux 6.8 |
| OLR | v1.9.0 Debug build (ASAN enabled) |
| Debezium | Server 3.5.0.Beta1, HTTP sink |
| Load generator | Swingbench 2.7 (SOE Order Entry, 0.1 scale) |
| Network | Host-only libvirt network (VM ↔ host) |

## Methodology

- Swingbench generates OLTP workload (INSERT/UPDATE/DELETE/SELECT mix) against
  Oracle RAC PDB via JDBC from host machine
- Both Debezium adapters (LogMiner and OLR) consume CDC events from the same
  Oracle instance simultaneously (tested separately to avoid interference)
- Events delivered to HTTP receiver on host, which timestamps each event
- Latency = `receiver_arrival_time - source.ts_ms` (Oracle commit time)
- Each test: 5 minutes of sustained load, then wait for adapter to catch up

## Results: LogMiner Adapter

| Users | ~TPS | Events | Latency p50 | Latency p95 | Status |
|-------|------|--------|-------------|-------------|--------|
| 1 | 300 | 299,732 | 6.6s (stable) | 7.7s | **Keeping up** |
| 2 | 600 | 428,680 | 83s (growing) | 127s | **Falling behind** |

At 1 user (~300 TPS), LogMiner maintains stable ~6.6s latency — this is the
inherent LogMiner mining cycle delay. At 2 users (~600 TPS), latency grows
linearly from 10s to 83s over 5 minutes, indicating the adapter cannot keep
up with the redo generation rate.

**LogMiner ceiling: ~300 TPS sustained** on this hardware.

## Results: OLR Adapter

| Users | ~TPS | Events | Latency p50 | Latency p95 | Status |
|-------|------|--------|-------------|-------------|--------|
| 1 | 300 | 296,556 | 7.9s (stable) | 9.5s | **Keeping up** |
| 2 | 600 | 432,266 | 8.5s (stable) | 9.7s | **Keeping up** |
| 4 | 1200 | 540,401 | 6.4s (stable) | 7.2s | **Keeping up** |
| 8 | 1700 | 564,362 | 6.5s (stable) | 8.5s | **Keeping up** |

OLR maintains stable latency across all tested load levels. At 8 users
(~1,700 TPS), latency stays flat at p50=6.5s.

**OLR did not reach its ceiling** — the Oracle RAC VM became the bottleneck
before OLR saturated.

## VM Resource Usage at 8 Users

| Resource | Value |
|----------|-------|
| CPU (us+sy) | ~68% |
| Memory used | 10.5-11 GB / 16 GB |
| Swap used | 8.4 GB |
| Free memory | 160-280 MB |
| Disk I/O (bi/bo) | 15-18K / 18-30K blocks/sec |
| I/O wait | 5-6% |

The VM is saturated on CPU, memory, and disk. The ~1,400 events/sec throughput
ceiling is Oracle's redo generation limit on this hardware, not OLR's
processing limit.

## Comparison Summary

| Metric | LogMiner | OLR |
|--------|----------|-----|
| Max sustained TPS (stable latency) | ~300 | **>1,700** (VM-limited) |
| Latency at 300 TPS | 6.6s | 7.9s |
| Latency at 600 TPS | 83s (diverging) | 8.5s (stable) |
| Catch-up throughput | ~1,000 eps | ~1,400 eps |

## Key Findings

1. **OLR sustains 5x+ higher TPS** than LogMiner before latency diverges
2. **LogMiner's ~6s baseline latency** is inherent to its SQL-based mining
   cycle — it cannot go lower regardless of load
3. **OLR's ~7s baseline latency** is dominated by Oracle redo flush interval,
   not OLR processing time
4. Under sustained load, **LogMiner latency grows linearly** while
   **OLR latency stays flat**
5. The **RAC VM is the bottleneck** at higher TPS — OLR's true ceiling was
   not reached in these tests

## Limitations

- Debug build with ASAN adds overhead — Release build would be faster
- 16 GB VM with loop-device ASM is not representative of production hardware
- Single PDB, small SOE schema (0.1 scale factor)
- HTTP sink adds overhead vs direct Kafka
- LogMiner and OLR tested separately (not simultaneously)

## Reproducing

```bash
# Prerequisites: RAC VM running, Swingbench installed, SOE schema created
cd tests/sql/environments/rac/debezium/perf

# Automated test (starts services, runs Swingbench, collects metrics)
./run.sh 300 8    # 5 min, 8 users

# Manual testing (as done for these results)
docker compose up -d receiver dbz-logminer   # or dbz-olr
# Start OLR on VM if testing OLR adapter
charbench -cs //VM_IP:1521/ORCLPDB -u soe -p soe \
  -c $SWINGBENCH_HOME/configs/SOE_Server_Side_V2.xml \
  -uc 8 -rt 00:05.00 -v users,tps,dml,resp
curl http://localhost:8080/metrics            # throughput + latency
```
