ZIG ?= /opt/homebrew/bin/zig
BUILD_DIR ?= /tmp/dory-p02-userspace-stress
SOURCE_SHA256 = $(shell cat stress.c Makefile | shasum -a 256 | cut -d ' ' -f 1)
CFLAGS = -std=c11 -O2 -Wall -Wextra -Werror -s -ffile-prefix-map=$(CURDIR)=/dory/p02-userspace-stress -fno-builtin-malloc -fno-builtin-calloc -fno-builtin-realloc -fno-builtin-free

.PHONY: all
all: $(BUILD_DIR)/p02-userspace-stress

# Cross-compilation only. There is deliberately no host execution/test target.
$(BUILD_DIR)/p02-userspace-stress: stress.c Makefile
	mkdir -p "$(BUILD_DIR)"
	"$(ZIG)" cc -target x86_64-linux-musl -mcpu=baseline -static $(CFLAGS) \
		-DDORY_STRESS_SOURCE_SHA256='"$(SOURCE_SHA256)"' stress.c -o "$@"
