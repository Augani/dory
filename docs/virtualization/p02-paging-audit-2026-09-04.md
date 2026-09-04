# P02 paging and CPU policy audit — 2026-09-04

This is a bounded source audit and regression-test change, not P02 completion or Linux qualification. `compatibleV1` remains an engineering candidate. PAE, PSE and PGE stay unadvertised; this change does not alter `DoryX86CPUProfile.swift`.

The primary reference is [Intel SDM revision 092, volume 3A](https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf), available through [Intel's SDM publication page](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html). Section numbering below is for revision 092.

| Source region | Correction and regression coverage | Reference |
| --- | --- | --- |
| `DoryX86Paging.swift`, `walkIA32e` | A 4 KiB PTE with PAT set retains a 4 KiB translation. Separate tests retain large-page PAT handling and reserved PML4/misaligned-large-page faults. | Tables 5-15 through 5-20 |
| `DoryX86Paging.swift`, `walkPAE`; `DoryX86Interpreter.swift`, `writeControlRegister` case 3 | Preserve CR3 root bits 11:5 for legacy PAE; the walker uses bits 31:5. Exercise three non-4-KiB-aligned roots and all four PDPTE selectors. Accept ignored low CR3 bits in legacy/IA-32e paging while retaining 4 KiB roots and reserved-high-bit/no-flush rejection. | §5.4.1, Tables 5-3/5-7/5-12; volume 2B, MOV to/from CR, page 4-32 |
| `DoryX86Paging.swift`, `walkPAE` | Derive permissions from PDE/PTE entries and leave valid PDPTE contents unchanged. Replace an existing invalid PDPTE fixture that used R/W and U/S. | §5.4.1, Table 5-8 |
| `DoryX86Paging.swift`, `walkLegacy32` | A PDE with bit 7 set still references a page table while PSE is clear; test both PSE settings. | §5.3 |
| `DoryX86Paging.swift`, `invalidate` | Evict every cached 4 KiB slice belonging to the addressed large page, including hot lookup slots. Test 2 MiB/1 GiB mappings, global/non-global entries and all three access kinds. | §5.10.4.1 and its large-page footnote |
| `DoryX86Paging.swift`, `faultCode` | Gate the instruction-fetch error bit on SMEP or PAE+NXE. Assert exact error codes for all combinations, both privilege classes and fetch/read/write accesses. | §5.7 |

`DoryX86PagingTests` contains 11 new test methods in this change, with 27 methods total. All 27 methods pass within [combined run 7](evidence/p02-correctness-2026-09-04/review-through-run-7.json), which records the exact source and complete results. This is the paging correction at commit `eb908d835`; later write-preflight work is recorded separately. The focused filter is `DoryX86PagingTests`.

Remaining concrete blockers:

- **PAE load semantics:** `walkPAE` still reads PDPTEs from guest memory on each uncached walk. There is no latched four-PDPTE state or atomic control-register load validation. Add that state, reject malformed present entries at the loading instruction, and test failed loads preserving the old state. Test subsequent memory edits remaining invisible until reload. A walker fault cannot substitute for the required control-load fault (§5.4.1).
- **Reserved paging bits:** `validate64BitEntry` does not reject PAE PDE/PTE bits 62:52. `walkLegacy32` silently drops large-page PDE bits 21:13 despite no PSE-36 advertisement. Add mode-specific masks and exact reserved-bit fault tests before enabling PAE/PSE (§5.3, §5.4.2). PAT support is also not exposed in the profile; PAT translation tests exercise the walker mechanism without qualifying a guest-visible PAT feature.
- **Control transitions and feature gates:** `writeControlRegister` accepts several CR4 features absent from CPUID and lacks the full PAE/long-mode/PCID transition checks. `writeModelSpecificRegister` accepts EFER.NXE independently of `executeDisable`. Test unsupported writes, unchanged state on failure, long-mode PAE invariants and PCID preconditions before promoting features. Broad invalidation is allowed; flushing global entries on MOV CR3 is not itself a PGE correctness defect (§5.10.4.1).
- **Privilege derivation:** `currentPrivilegeLevel` and `DoryX86PagingContext.init(state:mode:)` derive CPL from CS selector bits without handling virtual-8086 mode. This affects paging permissions and privileged operations. The parent is addressing HLT/SWAPGS separately; these broader helpers still need mode-aware tests.
- **Descriptor-table stores:** the `.descriptorTable` interpreter case only checks privilege for loads. SGDT/SIDT stores lack the CR4.UMIP restriction and bypass the common operand-access path. Before UMIP or wider privilege qualification, test restricted stores, segment/canonical-address faults and no partial writes. UMIP is currently unadvertised and CR4.UMIP writes are rejected.
- **ISA feature execution:** conservative CPUID masks do not by themselves gate every decoded x87/SIMD/optional instruction. A feature-by-instruction audit and negative execution tests remain necessary; this paging change does not establish x86-64-v2 support.

Instruction-specific primary references are [SDM volume 2A](https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf), HLT, page 3-439, and [SDM volume 2B](https://cdrdv2-public.intel.com/922481/253667-092-sdm-vol-2b.pdf), SGDT pages 4-628/629, SIDT pages 4-654/655 and SWAPGS pages 4-696/697. HLT needs separate real-mode and virtual-8086 treatment; SWAPGS is restricted to 64-bit mode. Those changes are owned by the parent task and are outside this paging patch.
