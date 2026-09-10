# Dory ARM64 DBT ABI

This document is normative for the tier-1 ARM64 translator. It separates the
stable vCPU context layout from the internal pinned-register convention. The
legacy baseline emitter and the opt-in tier-1 compiler both enter blocks through
the Darwin C ABI with the context pointer in `x0`. Tier-1 then installs the pinned
convention internally. Direct chains target complete block entries after the source
publishes architectural state and restores the target's entry arguments.

## Pinned register convention

| ARM64 register | Tier-1 owner | Contract |
| --- | --- | --- |
| `x0`...`x15` | guest GPRs | RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8...R15, in context order |
| `x16`, `x17` | translator | intra-procedure scratch and indirect helper/chain targets; never live across a helper |
| `x18` | Darwin | platform-reserved; generated code must never read or write it |
| `x19`...`x23` | dispatcher callbacks | memory context, read, write, compare-exchange, and synchronize arguments preserved from `x1`...`x5` |
| `x24` | dispatcher | reserved cache/chaining state; never allocated to a guest value |
| `x25`, `x26` | lazy flags | last materialized RFLAGS image and pending operation/count descriptor |
| `x27` | guest RIP | current architectural instruction pointer |
| `x28` | vCPU context | base of the stable context-word array and derived TLB state |
| `x29`, `x30` | host frame/link | standard frame pointer and link register |
| `sp` (`x31`) | host stack | 16-byte aligned at every call boundary |

The guest mapping is deliberately direct: guest register index `n` maps to
host `xn`. Partial-register writes are normalized before the value becomes live
again: 32-bit writes zero-extend, 8/16-bit writes merge, and AH/CH/DH/BH forms
are never represented as independent pinned values.

`x19`...`x28` are callee-saved by the Darwin ARM64 ABI. A tier-1 entry saves the
incoming host values before installing its own state. Its chain exit publishes
architectural state, restores the host frame and callback arguments, and then
tail-branches to the target's complete entry; pinned values never cross block
boundaries implicitly.

## Stable vCPU context

The context is an array of 95 little-endian `UInt64` words. It is not a Swift
struct ABI. The word layout is:

| Words | Contents |
| --- | --- |
| 0...15 | RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8...R15 |
| 16...20 | RIP, materialized RFLAGS, FS base, GS base, virtual TSC |
| 21...26 | CS, DS, ES, FS, GS, SS selectors |
| 27...30 | flat host reservation base; read, write, and execute TLB bases |
| 31...35 | TLB mask, address-space generation, reservation size, TLB storage, miss resolver |
| 36...37 | inline read/write hit-counter pointers |
| 38...42 | scalar compare-exchange, exchange, fetch-add, generic RMW, and pair compare-exchange helpers |
| 43...47 | lazy-flags operation plus count (low/high byte), width, result, source 1, and source 2 |
| 48...49 | lazy-flags materializer helper and per-dispatch materialization count |
| 50...53 | dispatch-entry/current CR3, IA32_KERNEL_GS_BASE, SWAPGS-performed marker, and CR3-write-performed marker |
| 54...58 | native-chain enable, remaining instruction budget, retired instructions, retired blocks, and last executed block's guest RIP |
| 59...63 | per-vCPU IBTC entry base, entry mask, code-cache generation, inline hits, and inline misses |
| 64...70 | per-vCPU shadow-return entry base, entry mask, top pointer, code-cache generation, inline hits, misses, and pushes |
| 71 | atomic pending-work byte in the low eight bits; the remaining bits are reserved |
| 72...73 | trusted incoming host frame pointer and return address for memory-capable generated blocks |
| 74 | generated BLR return PC for an architectural inline-TLB page fault |
| 75...93 | active memory-write checkpoint, exact GPR mask, entry RFLAGS, and RAX...R15 images |
| 94 | block-local restartable-read policy selected before the first memory callback |

The context pointer remains stable for a dispatch. TLB bases and helper
addresses are derived from it; generated code must not retain them beyond that
dispatch. New words append at the end so an older index never changes meaning.
Any persisted machine state contains architectural fields, not these host
pointers.

The dispatcher clears words 54...58 for ordinary single-block calls. Before a
native-chain call it sets word 54, publishes the instruction budget in word 55,
and clears the three result words. Every chainable block checks its own static
instruction count before entry, then atomically-with-respect-to-that-vCPU
decrements the remaining budget and increments words 56...57 only after a
successful architectural exit. Word 58 identifies the last block that retired,
allowing the dispatcher to extend a chain without guessing which target ran.
Words 59...61 expose the fixed 32-byte C IBTC entries to generated lookup code;
the generation is always nonzero while a table is active. Words 62...63 are
cleared at dispatch entry and accumulated into executor diagnostics on return.
Words 64...67 expose the fixed 32-byte C shadow-return entries and persistent
top word. Words 68...70 are per-dispatch generated hit, miss, and push counters.
Each entry is tagged with the guest RSP, guest return RIP, and code-cache
generation before its host target may be used.

Word 71 remains at one stable address for the executor's lifetime. Device and
coordination threads publish work with a release byte store; every chain-capable
block checks that byte before its instruction-budget guard and returns to the
dispatcher without retiring when it is nonzero. The check is disabled for
ordinary one-block execution. Because patched targets enter through the same
guard, block entry also bounds backward-branch interrupt latency without an
architectural spill at each guest instruction.

## Entry, exit, and chaining

The C dispatcher calls a block entry using the Darwin C ABI. A tier-1 entry
preserves the memory context and callback arguments in `x19`...`x23`, then loads
guest GPRs into `x0`...`x15`, RIP into `x27`, the last materialized RFLAGS
image into `x25`, the pending operation/count descriptor into `x26`, and installs
`x28`. A tier-1 chain exit reverses that boundary before its patch slot, so a
patched edge enters the target through its complete entry rather than a private
body label.

`DoryARM64Tier1BoundaryEmitter` is the executable implementation of these
boundaries. Its entry saves `x19`...`x30` in one 96-byte, 16-byte-aligned host
frame before installing pinned state. Its exit writes architectural state,
restores that frame, and returns a `DoryJITExitCode` through `w0`.

`DoryARM64Tier1Emitter` is admitted through the executor's `tier1Enabled`
feature flag. The PC machine enables it for the production baseline executor;
standalone executors retain an explicit opt-in so legacy/tier differential tests
can select either path. It compiles a whole supported IR block or declines it
without publishing code; a decline is compiled by the legacy baseline emitter.
Admitted blocks cover the producer and condition-consumer families
below plus direct and conditional terminators. Their compiled tier is reported
as `tier1` and contributes to the machine's baseline execution totals. Executor,
machine, UEFI-smoke, and PVH-runner diagnostics expose cumulative
`tier1CompilationAttempts`, `tier1CompilationDeclines`, and
`tier1CompiledBlocks` counters. An attempt is counted only after architectural
preflight submits an optimized IR block to tier-1; a decline is counted when
that emitter returns no block and the executor continues through the legacy
baseline emitter. Cache hits do not increment either compiler-boundary counter.

An exit publishes every dirty architectural value and the complete pending-flags
record to the context before returning an exit code. The executor materializes
that record before architectural state becomes externally visible and counts
that publication in the same diagnostic as generated materializer calls. The PC
run loop delivers pending interrupts only before the next processor execution,
after the preceding native return has crossed this publication boundary; an
interrupt consumer therefore never observes a tier-1-private lazy descriptor.
Interpreter, exception, interrupt, and code-cache exits must publish the precise
RIP of the next instruction to execute. A direct chain publishes nothing solely
for the chain; its target consumes the pinned state. Patched chain slots consult
context word 54 and remain block-local dispatcher exits while chaining is disabled.
This keeps one-block execution and recorded native-trace replay independent of
runtime link state. The chained dispatcher enables the slots only after validating
the complete reachable resident set against generation tokens or current bytes.

Direct chaining, the indirect-branch target cache, and the shadow-return stack
are independently selectable raw host-address predictors. A disabled predictor
cannot initiate its runtime link and its storage is absent from the generated
execution context. Shadow-return host targets depend on an enabled and populated
IBTC. The production PC machine currently selects the empty predictor set while
the remaining raw-target reliability investigation is open; standalone executor
use retains the complete predictor set by default.

The Swift dispatcher also materializes a pending tier-1 record before entering a
legacy baseline or optimizing resident in the same chain. Those emitters consume
only the architectural RFLAGS context word and cannot safely inherit the private
descriptor. Recorded native traces are therefore homogeneous by compilation tier;
trace replay cannot skip this tier-transition boundary.

## Native flags producers and fusion

`DoryARM64Tier1ALUEmitter` emits pinned-register ADD/ADC/SUB/SBB/CMP,
AND/TEST/OR/XOR, and INC/DEC/NEG producers for low 8-, 16-, 32-, and 64-bit
operands. Narrow writes merge only the architectural low part; their operands
are aligned to the ARM sign bit before flag-setting arithmetic so N/Z/C/V have
the x86 operand width. Narrow ADC/SBB retain exact results and lazy records but
require materialization before any condition consumer because ARM's unshifted
carry input cannot participate in that alignment. Each
producer stores its complete lazy record at words 43...47 while leaving ARM
NZCV live. A returned `NativeFlags` token may be used only by an immediately
adjacent fused consumer. ADC/SBB and carry-preserving INC/DEC require any older
pending record to be materialized before emission so `x25.CF` is current.
AH/CH/DH/BH binary and unary forms use the same aligned flag lowering and merge
only bits 8...15 of their legacy parent register; they are unavailable when REX
encoding would suppress the high-byte namespace.

Flag-neutral register MOV and NOT forms cover low 8-, 16-, 32-, and 64-bit
operands. Byte and word writes merge into the pinned parent, dword writes
zero-extend through a W-register operation, and qword writes replace the full
register. Their ARM instructions do not set NZCV or modify the lazy descriptor,
so a validated native-flags token can cross them into the next fused condition
consumer. The legacy baseline emitter admits the same word MOV/NOT forms so a
tier-1 decline never changes fallback coverage.

Qword register XCHG, dword/qword BSWAP, register MOVSX/MOVZX/MOVSXD, and
CDQ/CQO also operate directly on the pinned GPR bank. Their move, bitfield,
byte-reversal, and variable-shift encodings do not set NZCV, so neither the
lazy record nor an eligible native-flags token changes while they execute.

SHL/SHR/SAR/ROL/ROR/RCL/RCR producers accept immediate or pinned-CL counts at every
architectural width. They resolve older lazy flags before a nonzero operation,
mask counts according to x86 rules, preserve upper register parts, and publish a
dedicated lazy record. A masked-zero immediate leaves the older record intact; a
runtime masked-zero CL count resolves that record once and publishes no new one.
RCL/RCR use bounded bit loops, including modulo-9 and modulo-17 effective counts
for narrow operands. Shift/rotate consumers currently materialize rather than
claiming an NZCV token.

Register SHLD/SHRD producers cover their 16-, 32-, and 64-bit immediate and CL
forms. The 16-bit oversized-count path intentionally follows the interpreter's
deterministic zero result, while architectural flags remain represented by the
dedicated double-shift lazy operation.

Subtraction maps x86 CF to inverted ARM C: JB/JAE/JBE/JA therefore use CC/CS/LS/HI.
Addition maps CF directly to ARM C, so JB/JAE use CS/CC; JBE/JA after addition do
not have a single native condition and materialize. Logical operations treat CF
and OF as zero. ZF/SF/OF and signed comparisons map directly in every domain.
PF/NP always materialize. INC/DEC can fuse ZF/SF/OF and signed conditions, but
conditions involving their preserved CF materialize. The materializing SETcc
fallback evaluates all sixteen x86 conditions from `x25` and replaces only the
architectural destination byte. Native CMOV64 selects a pinned source without
clobbering NZCV, and a fused conditional terminator selects the next guest RIP
in `x27`; constant logical-domain predicates collapse to a move or no-op. Their
materializing fallbacks share the same complete predicate evaluator as SETcc.
CLC, STC, and CMC resolve an older lazy producer before replacing or toggling
the materialized CF bit. CLI, CLD, and STD change only a non-arithmetic bit in
the base image, so they leave a pending arithmetic record and eligible native
NZCV token intact; the later materializer preserves the updated IF/DF value.
LAHF and SAHF have explicit IR operations and share the materialization
boundary. LAHF replaces AH from the canonical low RFLAGS image. SAHF first
resolves any pending producer, then replaces only CF, PF, AF, ZF, and SF from
AH while preserving every other flag and forcing reserved bit 1. Native
long-mode admission for either operation requires the advertised `lahf64`
feature. PUSHF materializes the canonical image, clears RF and VM, sets bit 1,
and invokes the preserved scalar-write callback. Its temporary context and RSP
change are published only when the callback succeeds; callback failure returns
to the interpreter with the original architectural state.

Register/immediate PUSH, qword memory-source PUSH, and register POP use the same
restartable callback boundary. They materialize before borrowing the
lazy-payload words as staging storage, spill all pinned GPRs, preserve
pre-decrement PUSH RSP values, and give POP RSP its loaded-value precedence over
the ordinary increment. Memory-source PUSH reads and stages its qword through
the old register image before calculating the destination, including when the
source is based on RSP or aliases the destination. Its read-plus-write pair is
always admitted through the executor's replay-safe scalar-read path, so either
callback can fail while the temporary context and memory remain unpublished.
No later callback may follow a committed stack write.

Scalar memory-to-register MOV loads use the preserved read callback for 8-,
16-, 32-, and 64-bit operands. Tier-1 forms the complete base/index/scale,
displacement, RIP-relative, and optional FS/GS address before checkpointing all
guest GPRs. The callback result temporarily occupies the context RIP word while
the original pinned bank is restored; pinned `x27` remains authoritative and
replaces that staging value at exit. Loads preserve the pending lazy-flags
record, but the helper call invalidates any live native-NZCV token. Blocks with
more than one scalar read require replay-safe memory, and callback failure rolls
the entire block back to its executor checkpoint before interpreter fallback.
Memory-source CMOV first resolves a pending record, performs the source read
unconditionally, and only then evaluates its predicate from `x25`; a false CMOV
can therefore fault exactly like the interpreter. Qword selection preserves the
untaken destination, while dword selection zero-extends on either outcome. The
mandatory read uses the same replay and rollback contract as scalar MOV.
Register-destination ADD/ADC/SUB/SBB/CMP/AND/TEST/OR/XOR also accept scalar
memory sources at every integer width. The measured read-only word
memory-destination TEST-immediate family is also admitted. Both forms stage the
read before publishing the destination or replacement lazy-flags record, retain
the same native condition-fusion token as their register-only equivalents, and
share the replay and rollback contract above. Wider memory-destination and
memory-writing ALU forms remain outside tier 1 pending dedicated qualification
or an inline transactional write path.

The measured qword accumulator MUL memory-source form reads and stages its
operand before publishing RDX:RAX or replacing CF/OF. Effective addresses based
on the old RAX or RDX therefore remain exact. A qword register-to-memory MOV is
admitted only when it immediately follows that memory-source MUL and terminates
the same block through the transactional write callback; standalone and other
qword stores remain bounded. The store resolves pending flags before borrowing
the lazy-payload words for address and value staging. This measured read/write
pair requires replay-safe scalar memory, and failure at either callback rolls
the complete block back. Narrower memory-source accumulator MUL and every other
memory-store family remain outside tier 1 until independently measured and
qualified.

The measured byte-immediate `lock xor $1,(memory)` form is the sole tier-1
atomic ALU admission. It materializes an older lazy producer, forms the address
from the pinned register image, and retries the preserved scalar
compare-exchange callback until the observed byte matches. An initial expected
value of zero makes a mismatch supply the real byte without a separate read;
only the successful comparison writes memory. The old byte, immediate one, and
new byte then publish a width-eight logical lazy record. Callback failure leaves
that descriptor clear and causes the executor checkpoint to retry through the
interpreter. The callback shares the process-wide x86 atomic gate, so mixed
interpreter/tier-1 vCPUs remain single-copy. Every other byte immediate, source
kind, width, and atomic ALU operation remains outside tier 1. Linux lists this
measured instruction in `.smp_locks` and replaces its `0xf0` lock prefix with a
`0x3e` DS prefix when booting the uniprocessor guest. Tier 1 therefore also
admits the exact five-byte non-atomic `ds xor $1,(memory)` companion only at the
measured pinned-fixture RIP `0xffffffff8153a159`. It performs one replay-safe
byte read followed by a final transactional byte write, then publishes the same
logical lazy record. Failure at either callback rolls the complete instruction
back; all other non-atomic memory-writing ALU forms remain outside tier 1.

The measured five-byte `sete 0x23(%rsp)` block at pinned-fixture RIP
`0xffffffff815cab95` is the sole memory-destination SETcc admission. Tier 1
materializes any pending record, computes the predicate from `x25`, forms the
complete stack-relative address, and commits one byte through the transactional
write callback. The operation preserves architectural flags, clears condition
scratch before exit, and rolls the context back if the callback fails. Other
conditions, addresses, instruction shapes, and RIPs remain outside tier 1.

## Helper-call shim

A C helper may clobber `x0`...`x18` and NZCV. A generated shim therefore:

1. Computes a 16-bit live guest mask and spills exactly those pinned guest GPRs
   to context words 0...15. Dead guest values are not spilled.
2. Materializes RFLAGS before a helper whose `requiresMaterializedFlags` contract
   is set, and publishes RIP before every helper that can observe state, fault,
   interrupt, or request interpreter fallback.
3. Places the helper target in `x16`, marshals arguments in `x0`...`x7`, keeps
   `sp` 16-byte aligned, and executes `blr x16`.
4. Captures helper results before reloading the live guest registers. A result
   assigned to a guest register replaces that register's spilled value.
5. Treats `x16`, `x17`, NZCV, and every non-result caller-saved value as dead.
   `x19`...`x28` must survive by the host ABI; a debug shim may verify this.

Helper shims are the only generated-code path allowed to call C or Swift. A
helper that can exit must return through the dispatcher exit shim, never branch
directly to another translated block with partially restored state.
`DoryARM64Tier1BoundaryEmitter.HelperCall` makes the live mask, helper-table
slot, typed register arguments, and optional guest result explicit. Guest
arguments are reloaded from their checkpoint slots during marshalling, so
writing `x0`...`x7` cannot destroy a later argument.

## Invariants

- `DoryARM64Tier1ABI` is the executable source of truth for register numbers,
  context indices, and helper spill selection.
- Register ownership is injective; `x18`, `x29`, `x30`, and `sp` are never guest
  allocation candidates.
- Interpreter-to-JIT and JIT-to-interpreter transitions round-trip all 16 GPRs,
  RIP, RFLAGS, FS/GS bases, TSC, and visible segment selectors.
- CPL0 long-mode control-register reads may consume the CR3 snapshot at word 50. The two
  measured flushing CR3-write sites may update it and set word 53; the dispatcher then
  publishes CR3 and invalidates paging/JIT TLB state before another guest instruction runs.
  Every other control-register write remains interpreter-owned.
- CPL0 long-mode `SWAPGS` exchanges context words 19 and 51 without changing
  pinned GPRs or flags, then sets word 52; dispatcher publication uses that
  marker to mirror word 19 into both the visible GS descriptor base and
  IA32_GS_BASE without normalizing untouched state.
- Faultable memory helpers see a fully restartable architectural checkpoint.
- A05.2 may change the encoding held in `x25`/`x26`, but not their ownership or
  the materialized RFLAGS context index.
