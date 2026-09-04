CC = cc
CFLAGS = -O2 -std=c11 -Wall -Wextra -Werror
BUILD_DIR ?= /tmp/dory-p02-x86-reference
# Hash the exact byte concatenation in this order; the Swift receipt importer repeats it.
SOURCE_SHA256 = $(shell cat reference.c cases.def | shasum -a 256 | cut -d ' ' -f 1)

.PHONY: all vectors compare-receipt
all: $(BUILD_DIR)/p02-x86-reference

$(BUILD_DIR)/p02-x86-reference: reference.c cases.def Makefile
	mkdir -p "$(BUILD_DIR)"
	$(CC) $(CFLAGS) -DDORY_SOURCE_SHA256='"$(SOURCE_SHA256)"' reference.c -o "$@"

# Metadata generation does not execute the tested x86 instructions on any host.
vectors: all
	"$(BUILD_DIR)/p02-x86-reference" --vectors > vectors.json

# Missing input fails before Swift Testing can disable the optional receipt test.
compare-receipt:
	test -n "$(RECEIPT)"
	test -f "$(RECEIPT)"
	DORY_P02_X86_REFERENCE_RECEIPT="$(RECEIPT)" swift test --package-path ../../../dory-core-swift --filter explicitlyImportedPhysicalReceiptMatchesInterpreter
