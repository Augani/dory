# Bounded ISA inventory

`p02-isa-v1.json` is the unchanged decoder corpus. Its exact mode/byte vectors are
not a denominator for the architectural ISA. Decoding never counts as execution.

`p02-support-v1.json` adds four reviewed historical observations from the retained
run 30 gate at source `61cd728a4938e6e7e44319e0bd71f6147b115205`:

| Exact long64 bytes | Observation | Retired-form count |
| --- | --- | --- |
| `90` | NOP: interpreter/baseline native full-state agreement | 1 |
| `48 01 D8` | ADD RAX,RBX: recorded operands and RFLAGS agreement | 1 |
| `01 D8` | ADD EAX,EBX: recorded operands and RFLAGS agreement | 1 |
| `0F 01 C8` | MONITOR: expected interpreter #UD at CPL0/3 before operand access | 0 |

The MONITOR observation is one fault-attempt form. It does not establish native
JIT execution or successful retirement. A form executed by two engines is still
one unique form. Optimizing-JIT and physical-reference observations are unmeasured.
Unlisted forms and uncovered dimensions remain unmeasured.

Run from a checkout containing the retained evidence:

```sh
swift run --package-path dory-core-swift dory-x86-decode-audit --inventory --evidence-root .
```

Without `--evidence-root`, the tool searches the current directory and its parents
for the retained evidence directory. Outside a checkout it emits the static corpus
with no support catalog and zero executed-form counts. An explicitly selected or
discovered evidence root with missing, changed or inconsistent artifacts fails;
it never silently substitutes unverified support annotations. Tests can select a
separate checkout using `DORY_ISA_EVIDENCE_ROOT` with a relative or absolute path.

Validation hashes the original retained review receipt, gzip log, gzip manifest
and gzip source overlay. It requires a passing run, matching source revision,
empty tracked-source differences and an arm64 host (the native tests are gated on
that architecture). The source of each referenced test is read from the verified
archive, not from the current working tree. Exact file/manifest digests, method
range/excerpt digest, passed-test log line and case anchors must agree. Archive
reads are bounded and never extract files to disk.

Case mappings and their semantic scope are reviewed annotations: searching source
text does not prove arbitrary code executed. The exact passing test and archived
source make those annotations inspectable and reject stale bindings. The inventory
also checks the complete decoded vector, prefixes, operation and operand/address
sizes before attaching an annotation. A path, a decoded operation or a passed test
without an explicit matching execution case cannot increment coverage.

Historical evidence does not qualify later source revisions, all operands or
fault conditions, all JIT tiers, the physical reference backend, or the full ISA.
The current inventory invocation executes zero guest instructions. The JSON keeps
that count separate from historical retired forms and fault attempts.
