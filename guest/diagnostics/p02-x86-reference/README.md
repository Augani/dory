`p02-scalar12-v1` is a bounded physical x86-64 reference harness for P02-20. It covers
12 nonfaulting ADD, ADC, SUB, SBB, SHL, SHR, SAR, DIV and IDIV cases. No physical result
is checked in. Building it, generating vectors or passing the interpreter tests does
not complete P02-20.

The harness links no Dory code. `cases.def` is the single source for instruction bytes,
initial RAX/RBX/RCX/RDX/RFLAGS, expected values and output masks. The exact byte string
also appears in the inline assembly, so an assembler cannot silently choose a different
instruction form. `make vectors` atomically generates the checked-in `vectors.json`; its
origin is explicitly `specification-derived`, never a hardware observation. `make verify-vectors`
fails if the checked-in corpus differs byte-for-byte from current harness output.

Only those four GPRs and RFLAGS are part of the physical comparison. Other registers,
RIP, segments, exceptions, memory operands, SIMD and privileged state are outside this
corpus. All four GPR output masks are 64 bits, including the ADD EAX zero-extension case.
The inline assembly reserves the stack red zone, loads the requested arithmetic flags,
captures the actual complete RFLAGS immediately before the case bytes and immediately
after them, and restores the calling process's flags. A run fails if actual initial
RFLAGS differs from the declared input, including fixed bit 1 and user-mode IF.

Masks include defined arithmetic flags plus the preserved bit 1/IF. Nonzero shifts omit
undefined AF; shifts greater than one omit undefined OF. A count masked to zero preserves
the input flags. DIV/IDIV omit all six undefined arithmetic flags. Quotient, remainder
and unchanged input registers are compared exactly. These expectations follow Intel's
[instruction reference, volume 2](https://cdrdv2-public.intel.com/835757/325383-sdm-vol-2abcd.pdf),
entries ADD, ADC, SUB, SBB, SAL/SAR/SHL/SHR, DIV, IDIV and POPF/POPFD/POPFQ. The
[shift reference](https://cdrdv2-public.intel.com/782151/253667-sdm-vol-2b.pdf) specifies
the count-dependent flag definitions. Current official manuals are indexed by
[Intel](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

Build on a physical Intel or AMD x86-64 Linux or Intel macOS host with a C11 compiler,
`make`, and `shasum`. The build uses only libc and the compiler's CPUID header:

```sh
cd guest/diagnostics/p02-x86-reference
make
/tmp/dory-p02-x86-reference/p02-x86-reference --host-facts
```

The release build flags are fixed in the Makefile and recorded in receipt schema version
2. `make validate-source` additionally regenerates and compares the checked-in vectors,
then compiles the actual x86-64 inline assembly to an object without linking or executing
it. On a non-Darwin cross host, set `X86_64_CC` and `X86_64_ARCH_FLAGS` to a suitable
x86-64 C compiler and target flags. Passing this target validates source construction;
it is not physical instruction evidence.

Execution requires `--attest-physical-host` and operator/machine labels. The operator
attests that the process runs directly on a physical x86 machine with no emulator,
hypervisor or translation layer. The program additionally requires complete supported
host facts, an x86-64 kernel/executable, Intel or AMD CPUID, and no virtualization signal.
It refuses Rosetta using Apple's
[documented translation query](https://developer.apple.com/documentation/apple-silicon/about-the-rosetta-translation-environment),
ARM hardware, CPUID's
[hypervisor-present bit](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/tlfs/feature-discovery),
macOS `kern.hv_vmm_present`, and known virtual machine DMI/model identities. Missing
required sysctl or DMI facts refuse execution. These checks cannot prove physicality
against a hypervisor deliberately hiding every signal; the explicit attestation and
retained machine/build records are therefore required.

Use a new absolute receipt path outside the checkout. Preserve its command exit status,
the compiler/build log, executable hash, source commit and clean-tree status alongside it:

```sh
git rev-parse HEAD
git status --porcelain
shasum -a 256 /tmp/dory-p02-x86-reference/p02-x86-reference
( set -C; /tmp/dory-p02-x86-reference/p02-x86-reference --run --attest-physical-host --operator YOUR_NAME --machine-id YOUR_PHYSICAL_ASSET > /absolute/new-physical-receipt.json )
```

Exit 0 means all 12 physical cases matched their masks. Exit 1 means mismatch or output
failure; exit 2 means refused host, absent attestation, unavailable source identity or
invalid arguments. Refusal JSON is unqualified. Never reinterpret a refusal or a missing
receipt as a passing hardware gate. The source identity is SHA-256 of the byte
concatenation `reference.c`, `cases.def`, then `Makefile`, computed at build time.
Regenerate the receipt whenever any of those files changes. Retain the binary hash
independently; the receipt is an engineering result, not a signed hardware attestation or
whole-ISA proof.

Copy the successful JSON to the Dory validation host using the same source checkout.
This command requires a real file and enables the otherwise disabled hardware test:

```sh
make compare-receipt RECEIPT=/absolute/new-physical-receipt.json
```

The importer checks receipt schema version 2, fixed build flags, the source digest, host
facts, attestation, operator and machine-label syntax, complete ordered case set,
exact bytes/inputs/expected values/masks, actual initial flags and observed outputs. It
then executes the same bytes in the Dory interpreter and compares only defined outputs.
Without `DORY_P02_X86_REFERENCE_RECEIPT`, that test is disabled and physical qualification
remains unavailable. The ordinary `DoryX86PhysicalReferenceTests` corpus and parser tests
are specification/parser checks only; their synthetic in-memory parser envelope is not
persisted or counted as physical evidence.

On ARM, `make vectors` is safe metadata generation and `--host-facts`/`--run` refuse
physical qualification. `make check-x86_64-object` validates the x86 assembly build path
without running it; never execute that object through Rosetta and call it a physical
reference.
