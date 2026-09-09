# Dory ARM64 DBT ABI

This document is normative for the tier-1 ARM64 translator. It separates the
stable vCPU context layout from the internal pinned-register convention. The
legacy baseline emitter and the opt-in tier-1 compiler both enter standalone
blocks through the Darwin C ABI with the context pointer in `x0`. Tier-1 then
installs the pinned convention internally; direct chaining will replace those
per-block boundaries atomically in the dispatcher.

## Pinned register convention

| ARM64 register | Tier-1 owner | Contract |
| --- | --- | --- |
| `x0`...`x15` | guest GPRs | RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8...R15, in context order |
| `x16`, `x17` | translator | intra-procedure scratch and indirect helper/chain targets; never live across a helper |
| `x18` | Darwin | platform-reserved; generated code must never read or write it |
| `x19`...`x24` | dispatcher | callee-saved dispatcher state, helper table, and cache/chaining state; never allocated to a guest value |
| `x25`, `x26` | lazy flags | last materialized RFLAGS image and pending operation/count descriptor |
| `x27` | guest RIP | current architectural instruction pointer |
| `x28` | vCPU context | base of the stable context-word array and derived TLB state |
| `x29`, `x30` | host frame/link | standard frame pointer and link register |
| `sp` (`x31`) | host stack | 16-byte aligned at every call boundary |

The guest mapping is deliberately direct: guest register index `n` maps to
host `xn`. Partial-register writes are normalized before the value becomes live
again: 32-bit writes zero-extend, 8/16-bit writes merge, and AH/CH/DH/BH forms
are never represented as independent pinned values.

`x19`...`x28` are callee-saved by the Darwin ARM64 ABI. The dispatcher saves the
incoming host values once before installing its own state and restores them on
the final return to Swift/C. A chained block inherits all pinned values without
a prologue or epilogue.

## Stable vCPU context

The context is an array of 50 little-endian `UInt64` words. It is not a Swift
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

The context pointer remains stable for a dispatch. TLB bases and helper
addresses are derived from it; generated code must not retain them beyond that
dispatch. New words append at the end so an older index never changes meaning.
Any persisted machine state contains architectural fields, not these host
pointers.

## Entry, exit, and chaining

The C dispatcher initially calls an entry shim using the Darwin C ABI. The shim
loads guest GPRs into `x0`...`x15`, RIP into `x27`, the last materialized RFLAGS
image into `x25`, the pending operation/count descriptor into `x26`, and installs
`x28`. Direct chains branch to a tier-1 block entry after this setup and therefore
cannot target the C entry shim.

`DoryARM64Tier1BoundaryEmitter` is the executable implementation of these
boundaries. Its entry saves `x19`...`x30` in one 96-byte, 16-byte-aligned host
frame before installing pinned state. Its exit writes architectural state,
restores that frame, and returns a `DoryJITExitCode` through `w0`.

`DoryARM64Tier1Emitter` is admitted through the executor's `tier1Enabled`
feature flag. It compiles a whole register-only IR block or declines it without
publishing code; a decline is compiled by the legacy baseline emitter. Admitted
blocks cover the producer and condition-consumer families below plus direct and
conditional terminators. Their compiled tier is reported as `tier1`.

An exit publishes every dirty architectural value and the complete pending-flags
record to the context before returning an exit code. The executor materializes
that record before architectural state becomes externally visible. Interpreter,
exception, interrupt, and code-cache exits must publish the precise RIP of the
next instruction to execute. A direct chain publishes nothing solely for the
chain; its target consumes the pinned state.

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
LAHF consumes the same boundary and replaces AH from the canonical low RFLAGS
image; PUSHF lowering receives an image with RF and VM cleared and bit 1 set
before the tier-1 memory path performs the stack write.

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
- Faultable memory helpers see a fully restartable architectural checkpoint.
- A05.2 may change the encoding held in `x25`/`x26`, but not their ownership or
  the materialized RFLAGS context index.
