/* Bounded independent architectural reference; no Dory CPU code is linked. */
#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <time.h>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif
#if defined(__x86_64__)
#include <cpuid.h>
#endif

#ifndef DORY_SOURCE_SHA256
#define DORY_SOURCE_SHA256 "unavailable"
#endif
#ifndef DORY_BUILD_FLAGS
#define DORY_BUILD_FLAGS "unavailable"
#endif
#define HEX_(value) UINT64_C(0x##value)
#define HEX(value) HEX_(value)
#define CORPUS "p02-scalar12-v1"

struct state { uint64_t rax, rbx, rcx, rdx, rflags; };
struct vector {
  const char *id, *bytes;
  struct state initial, expected;
  uint64_t flags_mask;
};
enum case_index {
#define CASE(id, bytes, a, b, c, d, f, ea, ed, mask, ef) case_##id,
#include "cases.def"
#undef CASE
};
static const struct vector vectors[] = {
#define CASE(id, bytes, a, b, c, d, f, ea, ed, mask, ef) \
  {#id, bytes, {HEX(a), HEX(b), HEX(c), HEX(d), HEX(f)}, \
   {HEX(ea), HEX(b), HEX(c), HEX(ed), HEX(ef)}, HEX(mask)},
#include "cases.def"
#undef CASE
};
enum { vector_count = sizeof(vectors) / sizeof(vectors[0]) };
struct observation { struct state final; uint64_t initial_flags; bool passed; };
struct host {
  char machine[256], os[256], release[256], vendor[64], model[256], cpu[64];
  char reason[160];
  uint32_t leaf1_eax, leaf1_ecx;
  bool translated, virtualization, facts_complete;
};

static void string(const char *s) {
  putchar('"');
  for (const unsigned char *p = (const unsigned char *)s; *p; ++p) {
    if (*p == '"' || *p == '\\') printf("\\%c", *p);
    else if (*p < 32 || *p >= 127) printf("\\u%04x", *p);
    else putchar(*p);
  }
  putchar('"');
}
static void state_json(const struct state *s) {
  printf("{\"rax\":\"%016" PRIx64 "\",\"rbx\":\"%016" PRIx64
         "\",\"rcx\":\"%016" PRIx64 "\",\"rdx\":\"%016" PRIx64
         "\",\"rflags\":\"%016" PRIx64 "\"}", s->rax, s->rbx, s->rcx, s->rdx, s->rflags);
}
static void vector_json(size_t i, const struct observation *o) {
  const struct vector *v = &vectors[i];
  printf("{\"id\":"); string(v->id);
  printf(",\"bytes\":[");
  const char *p = v->bytes;
  bool first = true;
  while (*p) {
    char *end;
    unsigned long byte = strtoul(p, &end, 16);
    if (end == p || byte > 255) abort();
    printf("%s%lu", first ? "" : ",", byte);
    first = false;
    p = *end == ',' ? end + 1 : end;
  }
  printf("],\"initial\":"); state_json(&v->initial);
  printf(",\"expected\":"); state_json(&v->expected);
  printf(",\"masks\":{\"rax\":\"ffffffffffffffff\",\"rbx\":\"ffffffffffffffff\","
         "\"rcx\":\"ffffffffffffffff\",\"rdx\":\"ffffffffffffffff\",\"rflags\":\"%016" PRIx64 "\"}", v->flags_mask);
  if (o) {
    printf(",\"observedInitialRFLAGS\":\"%016" PRIx64 "\",\"observed\":", o->initial_flags);
    state_json(&o->final);
    printf(",\"passed\":%s", o->passed ? "true" : "false");
  }
  putchar('}');
}

static bool virtual_name(const char *name) {
  char lower[512];
  size_t count = strlen(name);
  if (count >= sizeof(lower)) return true;
  for (size_t i = 0; i <= count; ++i) lower[i] = (char)tolower((unsigned char)name[i]);
  const char *needles[] = {"virtual", "vmware", "qemu", "kvm", "xen", "bochs", "hyper-v",
    "parallels", "bhyve", "openstack", "amazon ec2", "google compute", "nutanix"};
  for (size_t i = 0; i < sizeof(needles) / sizeof(needles[0]); ++i)
    if (strstr(lower, needles[i])) return true;
  return false;
}
#if defined(__linux__)
static bool read_fact(const char *path, char *out, size_t capacity) {
  FILE *file = fopen(path, "r");
  if (!file) return false;
  size_t n = fread(out, 1, capacity - 1, file);
  bool ok = !ferror(file) && feof(file);
  int saved_errno = ferror(file) ? EIO : EINVAL;
  fclose(file);
  while (n && isspace((unsigned char)out[n - 1])) --n;
  out[n] = 0;
  errno = ok && n > 0 ? 0 : saved_errno;
  return ok && n > 0;
}
#endif
static struct host host_facts(void) {
  struct host h = {0};
  struct utsname u;
  if (uname(&u) != 0) { strcpy(h.reason, "uname unavailable"); return h; }
  snprintf(h.machine, sizeof(h.machine), "%s", u.machine);
  snprintf(h.os, sizeof(h.os), "%s", u.sysname);
  snprintf(h.release, sizeof(h.release), "%s", u.release);
#if defined(__APPLE__)
  int translated = 0, arm64 = 0, vmm = 0;
  size_t n = sizeof(translated);
  int result = sysctlbyname("sysctl.proc_translated", &translated, &n, NULL, 0);
  if (result != 0 && errno != ENOENT) { strcpy(h.reason, "translation status unavailable"); return h; }
  h.translated = translated != 0;
  n = sizeof(arm64);
  result = sysctlbyname("hw.optional.arm64", &arm64, &n, NULL, 0);
  if (result != 0 && errno != ENOENT) { strcpy(h.reason, "hardware architecture unavailable"); return h; }
  if (h.translated || arm64) { strcpy(h.reason, "ARM hardware or Rosetta translation refused"); return h; }
  n = sizeof(vmm);
  if (sysctlbyname("kern.hv_vmm_present", &vmm, &n, NULL, 0) != 0) {
    strcpy(h.reason, "hypervisor status unavailable"); return h;
  }
  h.virtualization = vmm != 0;
  n = sizeof(h.model);
  if (sysctlbyname("hw.model", h.model, &n, NULL, 0) != 0 || !n || n >= sizeof(h.model)) {
    strcpy(h.reason, "hardware model unavailable"); return h;
  }
  h.model[sizeof(h.model) - 1] = 0;
  strcpy(h.vendor, "Apple Inc.");
#elif defined(__linux__)
  if (!read_fact("/sys/class/dmi/id/sys_vendor", h.vendor, sizeof(h.vendor)) ||
      !read_fact("/sys/class/dmi/id/product_name", h.model, sizeof(h.model))) {
    strcpy(h.reason, "DMI physical-host facts unavailable"); return h;
  }
  char hypervisor[256];
  if (read_fact("/sys/hypervisor/type", hypervisor, sizeof(hypervisor))) h.virtualization = true;
  else if (errno != ENOENT) { strcpy(h.reason, "hypervisor type unavailable"); return h; }
#else
  strcpy(h.reason, "unsupported host OS"); return h;
#endif
  h.virtualization = h.virtualization || virtual_name(h.vendor) || virtual_name(h.model);
#if defined(__x86_64__)
  if (strcmp(h.machine, "x86_64") != 0) { strcpy(h.reason, "non-x86_64 kernel refused"); return h; }
  unsigned int a, b, c, d;
  if (!__get_cpuid(0, &a, &b, &c, &d)) { strcpy(h.reason, "CPUID unavailable"); return h; }
  memcpy(h.cpu, &b, 4); memcpy(h.cpu + 4, &d, 4); memcpy(h.cpu + 8, &c, 4);
  if (strcmp(h.cpu, "GenuineIntel") && strcmp(h.cpu, "AuthenticAMD")) {
    strcpy(h.reason, "unqualified CPU vendor"); return h;
  }
  if (!__get_cpuid(1, &a, &b, &c, &d)) { strcpy(h.reason, "CPUID leaf 1 unavailable"); return h; }
  h.leaf1_eax = a; h.leaf1_ecx = c;
  h.virtualization = h.virtualization || (c & (1u << 31)) != 0;
  h.facts_complete = true;
  if (h.virtualization) strcpy(h.reason, "virtualized host refused");
#else
  strcpy(h.reason, "non-x86_64 executable refused");
#endif
  return h;
}
static void host_json(const struct host *h) {
  printf("{\"machine\":"); string(h->machine);
  printf(",\"os\":"); string(h->os);
  printf(",\"release\":"); string(h->release);
  printf(",\"systemVendor\":"); string(h->vendor);
  printf(",\"model\":"); string(h->model);
  printf(",\"cpuVendor\":"); string(h->cpu);
  printf(",\"cpuidLeaf1EAX\":\"%08" PRIx32 "\",\"cpuidLeaf1ECX\":\"%08" PRIx32
         "\",\"translated\":%s,\"virtualizationDetected\":%s,\"factsComplete\":%s,\"refusal\":",
         h->leaf1_eax, h->leaf1_ecx, h->translated ? "true" : "false",
         h->virtualization ? "true" : "false", h->facts_complete ? "true" : "false");
  string(h->reason); putchar('}');
}

#if defined(__x86_64__)
static struct observation execute(size_t index) {
  const struct vector *v = &vectors[index];
  uint64_t a = v->initial.rax, b = v->initial.rbx, c = v->initial.rcx, d = v->initial.rdx;
  register uint64_t before __asm__("r8");
  register uint64_t after __asm__("r9");
  register uint64_t requested __asm__("r10") = v->initial.rflags;
  /* LEA leaves flags untouched. Reserve the red zone before PUSHFQ/POPFQ, so compiler
   * temporaries cannot be corrupted. Capture actual input flags immediately before
   * the exact case bytes, output flags immediately after, then restore host flags. */
  switch (index) {
#define CASE(id, bytes, ia, ib, ic, id_, f, ea, ed, mask, ef) \
  case case_##id: \
    __asm__ volatile("leaq -128(%%rsp), %%rsp\n\t" \
      "pushfq\n\tpopq %%r11\n\tpushq %%r10\n\tpopfq\n\t" \
      "pushfq\n\tpopq %%r8\n\t.byte " bytes "\n\t" \
      "pushfq\n\tpopq %%r9\n\tpushq %%r11\n\tpopfq\n\t" \
      "leaq 128(%%rsp), %%rsp" \
      : "+a"(a), "+b"(b), "+c"(c), "+d"(d), "=r"(before), "=r"(after) \
      : "r"(requested) : "r11", "cc", "memory"); \
    break;
#include "cases.def"
#undef CASE
    default: abort();
  }
  struct observation o = {{a, b, c, d, after}, before, false};
  o.passed = before == v->initial.rflags && a == v->expected.rax && b == v->expected.rbx &&
    c == v->expected.rcx && d == v->expected.rdx && (after & v->flags_mask) == v->expected.rflags;
  return o;
}
#endif

static bool label_valid(const char *value) {
  if (!value || !*value || strlen(value) > 80) return false;
  for (const unsigned char *p = (const unsigned char *)value; *p; ++p)
    if (*p < 32 || *p >= 127) return false;
  return true;
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--vectors")) {
    printf("{\"schemaVersion\":1,\"corpus\":\"" CORPUS "\",\"origin\":\"specification-derived\",\"cases\":[");
    for (size_t i = 0; i < vector_count; ++i) { if (i) putchar(','); vector_json(i, NULL); }
    puts("]}");
    return ferror(stdout) ? 1 : 0;
  }
  struct host h = host_facts();
  if (argc == 2 && !strcmp(argv[1], "--host-facts")) {
    printf("{\"schemaVersion\":1,\"qualified\":%s,\"host\":",
      !h.reason[0] && h.facts_complete ? "true" : "false");
    host_json(&h); puts("}");
    return h.reason[0] || !h.facts_complete ? 2 : 0;
  }
  if (argc != 7 || strcmp(argv[1], "--run") || strcmp(argv[2], "--attest-physical-host") ||
      strcmp(argv[3], "--operator") || strcmp(argv[5], "--machine-id") ||
      !label_valid(argv[4]) || !label_valid(argv[6])) {
    fputs("usage: p02-x86-reference --vectors | --host-facts | --run --attest-physical-host --operator NAME --machine-id ASSET\n", stderr);
    return 2;
  }
  if (h.reason[0] || !h.facts_complete || strlen(DORY_SOURCE_SHA256) != 64) {
    printf("{\"schemaVersion\":1,\"qualified\":false,\"status\":\"refused\",\"host\":");
    host_json(&h); puts("}");
    return 2;
  }
#if defined(__x86_64__)
  struct observation observations[vector_count];
  bool passed = true;
  for (size_t i = 0; i < vector_count; ++i) {
    observations[i] = execute(i);
    passed = passed && observations[i].passed;
  }
  printf("{\"schemaVersion\":2,\"corpus\":\"" CORPUS "\",\"status\":\"%s\","
         "\"execution\":\"physical-x86_64\",\"physicalAttestation\":true,\"sourceSHA256\":\""
         DORY_SOURCE_SHA256 "\",\"compiler\":", passed ? "passed" : "mismatch");
  string(__VERSION__);
  printf(",\"buildFlags\":"); string(DORY_BUILD_FLAGS);
  printf(",\"operator\":"); string(argv[4]); printf(",\"machineID\":"); string(argv[6]);
  printf(",\"unixTime\":%jd,\"host\":", (intmax_t)time(NULL)); host_json(&h);
  printf(",\"cases\":[");
  for (size_t i = 0; i < vector_count; ++i) { if (i) putchar(','); vector_json(i, &observations[i]); }
  puts("]}");
  return passed && !ferror(stdout) ? 0 : 1;
#else
  return 2;
#endif
}
