CC ?= cc
X86_64_CC ?= $(CC)
BUILD_DIR ?= /tmp/dory-p02-x86-reference
override HARNESS_CFLAGS := -O2 -std=c11 -Wall -Wextra -Werror
HOST_OS := $(shell uname -s)
X86_64_ARCH_FLAGS ?= $(if $(filter Darwin,$(HOST_OS)),-arch x86_64,-m64)
SOURCE_FILES := reference.c cases.def Makefile
# Hash the exact byte concatenation in this order; the Swift receipt importer repeats it.
SOURCE_SHA256 := $(shell cat $(SOURCE_FILES) | shasum -a 256 | cut -d ' ' -f 1)

.DELETE_ON_ERROR:
.PHONY: all vectors verify-vectors check-x86_64-object validate-source compare-receipt
all: $(BUILD_DIR)/p02-x86-reference

$(BUILD_DIR)/p02-x86-reference: reference.c cases.def Makefile
	mkdir -p "$(BUILD_DIR)"
	$(CC) $(HARNESS_CFLAGS) -DDORY_SOURCE_SHA256='"$(SOURCE_SHA256)"' \
		-DDORY_BUILD_FLAGS='"$(HARNESS_CFLAGS)"' reference.c -o "$@"

# Metadata generation does not execute the tested x86 instructions on any host.
vectors: all
	@temporary="$(BUILD_DIR)/vectors.generated.$$$$.json"; \
		trap 'rm -f "$$temporary"' EXIT; \
		"$(BUILD_DIR)/p02-x86-reference" --vectors > "$$temporary"; \
		mv "$$temporary" vectors.json; \
		trap - EXIT

verify-vectors: all
	@temporary="$(BUILD_DIR)/vectors.verified.$$$$.json"; \
		trap 'rm -f "$$temporary"' EXIT; \
		"$(BUILD_DIR)/p02-x86-reference" --vectors > "$$temporary"; \
		cmp vectors.json "$$temporary"

# Compile, but never link or execute, the actual x86 inline assembly.
check-x86_64-object:
	mkdir -p "$(BUILD_DIR)"
	$(X86_64_CC) $(HARNESS_CFLAGS) $(X86_64_ARCH_FLAGS) \
		-DDORY_SOURCE_SHA256='"$(SOURCE_SHA256)"' -DDORY_BUILD_FLAGS='"$(HARNESS_CFLAGS)"' \
		-c reference.c -o "$(BUILD_DIR)/p02-x86-reference.x86_64.o"

validate-source: verify-vectors check-x86_64-object

# Missing input fails before Swift Testing can disable the optional receipt test.
compare-receipt:
	test -n "$(RECEIPT)"
	test -f "$(RECEIPT)"
	DORY_P02_X86_REFERENCE_RECEIPT="$(RECEIPT)" swift test --package-path ../../../dory-core-swift --filter explicitlyImportedPhysicalReceiptMatchesInterpreter
