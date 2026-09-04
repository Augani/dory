# P02 raw block and Ethernet IO fixture

This separate fixture adds two bounded guest workloads to P02-25 evidence. It
does not modify or include the seven-workload `p02-userspace-stress` v1 program.
Its guest C program requires Linux x86-64, a canonical UUID from exactly one
`dory.pvh_run_id` token, and a supervising PID 1 before it performs IO. Never run
the binary or init script on the host, including through Rosetta or an emulator.

The guest requires the host runner's explicit isolated diagnostic PCI block and
network devices: a fresh 32 MiB backing file exposed as `/dev/vda`, and a virtual
Ethernet peer. No host network interface or socket is used. The host must retain
its own block-operation and frame counters and independently verify the backing
file after reopening it. Guest output alone is insufficient acceptance evidence.

## Exact workloads

`io.block_flush_reopen` opens `/dev/vda` with O_EXCL and rejects anything other
than a block device reporting exactly 33,554,432 bytes through BLKGETSIZE64. Eight
rounds write the same 131,072-byte region at offset 1,048,576, call fsync, close,
reopen and read every byte back. At zero-based index `i` within that region, the
byte is `(i * 37 + (i >> 8)) mod 256`. The expected region SHA-256 is
`dbb71d178d43f63f39dd9b0fb5fc30fb366ada39e3b8763e41338b892c098cd6`.
No filesystem is mounted and no other disk region is written. Host acceptance
requires at least one actual virtio flush and the exact pattern read through a
new host file descriptor. A guest reopen may read page cache, and Linux can treat
unsupported device flush as successful fsync; those are why the independent host
checks are required. This is raw block/backend verification, not filesystem
journal recovery, physical-media durability or VM-restart qualification.

`io.ethernet_frame_roundtrip` uses AF_PACKET on `eth0`, verifies the guest MAC,
brings the interface up and binds only EtherType 0x88B5. It sets
PACKET_IGNORE_OUTGOING and additionally rejects outgoing/non-host packets from
the acceptance path. It allows at most 64 irrelevant packets. A matching peer
packet with altered length, UUID, sequence or payload immediately fails. There is
one outstanding request and no retransmission of a successfully sent frame.

Every frame has exactly 1024 bytes, including its Ethernet header and excluding
the FCS. Multi-byte integers use big-endian encoding:

| Offset | Length | Request value |
| --- | --- | --- |
| 0 | 6 | Destination `02:d0:52:00:00:02` |
| 6 | 6 | Source `02:d0:52:00:00:01` |
| 12 | 2 | EtherType `0x88b5` |
| 14 | 8 | ASCII `DORYIO01` |
| 22 | 16 | UUID decoded as raw bytes in canonical text order |
| 38 | 4 | Sequence, beginning at zero |
| 42 | 2 | Data length, 980 |
| 44 | 980 | Byte `i = (sequence * 17 + i * 37 + (i >> 8)) mod 256` |

The peer response swaps only the first two MAC fields; all other bytes are
unchanged. The guest validates 4096 or more echoed frames over at least five
guest monotonic seconds, capped at 16,384 frames and a 30-second deadline. Sends
are paced at least 1.25 ms apart. The reported elapsed interval starts immediately
before the first successful send and ends immediately after the last validated
reply; idle time after that reply does not contribute to the minimum interval.
The peer is pumped between VM execution quanta. This exercises virtio and the
kernel Ethernet path; it does not establish TCP/IP, external connectivity,
physical-NIC behavior or throughput qualification.

## Receipt and resource limits

Each stage emits a `DORY_P02_RESULT` with the exact run UUID, name and pass/fail
status. Only both successful stages produce the normal unprefixed runner receipt
with those two exact workload names, plus:

```json
"ioNetwork": {"frames": 4096, "bytes": 4194304, "elapsedNanoseconds": 5000000000}
```

Those numbers illustrate the field meanings; actual values come from the run.
`frames` counts validated replies, and `bytes` is `frames * 1024`, not doubled
TX+RX traffic. The host must exactly reconcile accepted requests and delivered
responses against these fields, require drained queues, reject any sticky peer
error and independently observe ACPI S5 poweroff. Missing fields, budget
exhaustion, incomplete stages or a receipt without poweroff fail acceptance.

The C program has a 60-second aggregate guest monotonic deadline, 30-second stage
deadlines, a 60 CPU-second limit, 32 file descriptors, disabled core dumps, at
most 256 KiB of explicit heap buffers, one packet socket and no child processes.
Its regular-file diagnostic output is capped at 32 KiB; the init adapter accepts
at most 16 KiB for publication. Blocking kernel IO and a faulty guest clock
still require the runner's independent instruction and monotonic wall budgets.

The init adapter mounts procfs, devtmpfs, sysfs and an 8 MiB tmpfs, checks the
exact kernel release and UUID, then loads five pinned modules with explicit
`insmod` calls in dependency order. It polls for the two device nodes at most
1000 times with 10 ms sleeps before invoking C. It buffers C output until exit 0
and final sync pass. A delivery failure after publication begins never proceeds
to successful poweroff. The original seven-workload stress archive remains a
separate, unchanged qualification input.

## Pinned driver closure

All drivers come from the already catalog-pinned Alpine 3.24.1 x86-64 initramfs
for kernel `6.18.35-0-virt`. No additional download or modloop runtime is needed.
The minimal closure is `virtio_blk`, `failover`, `net_failover`, `virtio_net`,
`af_packet`, totaling 590,755 uncompressed bytes. PCI, MSI, virtio core/ring,
modern/legacy PCI transport and virtio-mmio are built in. Do not add fictitious
`virtio_pci.ko` or `virtio_ring.ko` payloads. The module bytes carry the matching
vermagic and kernel signature trailer; the preparer checks full pinned hashes,
and actual kernel loading remains runtime evidence.

Build through the adjacent Makefile with Zig 0.15.2 and explicit output directory;
it only cross-compiles a stripped static `x86_64-linux-musl` executable. The source
digest is SHA-256 of `stress.c` followed by `Makefile`. The fixture preparer
requires explicit ELF and pinned build-metadata paths; it never compiles or runs
guest code. A source build or prepared archive is not a successful guest test.

From the repository root, with verified Alpine inputs already cached:

```sh
make -j1 -C guest/diagnostics/p02-userspace-io-stress \
  BUILD_DIR=/tmp/dory-p02-userspace-io-stress
python3 scripts/prepare-virtualization-fixtures.py \
  --id alpine-virt-3.24.1-x86_64 \
  --cache-directory /tmp/dory-p00-guest-fixtures \
  --verify-only --extract --io-stress-diagnostic-initramfs \
  --stress-binary /tmp/dory-p02-userspace-io-stress/p02-userspace-io-stress \
  --stress-build-metadata guest/diagnostics/p02-userspace-io-stress/build.json
python3 scripts/test-prepare-virtualization-fixtures.py
```

Use a new cache for changed builder provenance; existing mismatched records are
preserved. Two local source-directory builds produced the same 40,712-byte ELF,
SHA-256 `72eee711647f609d8f7dac5b87429038d7f2fdb97d7ba6d1240532add7a5f9b5`.
This establishes source-path independence on one Zig 0.15.2 macOS ARM64 host,
not cross-host compiler-distribution reproducibility. The pinned uncompressed
`x86_64-p02-userspace-io-stress-v1.cpio` is 2,114,560 bytes, SHA-256
`cbd5f9a8716052abfe710da732b70e6a2e8b038c7603387e943787b051578a35`.

The IO contracts follow the Linux man-pages
[packet interface](https://man7.org/linux/man-pages/man7/packet.7.html) and Linux
6.18's [block file operations](https://github.com/torvalds/linux/blob/v6.18/block/fops.c).
