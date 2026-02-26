# ################################################################
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under both the BSD-style license (found in the
# LICENSE file in the root directory of this source tree) and the GPLv2 (found
# in the COPYING file in the root directory of this source tree).
# You may select, at your option, one of the above-listed licenses.
# ################################################################

# verbose mode (print commands) on V=1 or VERBOSE=1
Q = $(if $(filter 1,$(V) $(VERBOSE)),,@)

PRGDIR   = programs
ZSTDDIR  = lib
BUILDIR  = build
ZWRAPDIR = zlibWrapper
TESTDIR  = tests
FUZZDIR  = $(TESTDIR)/fuzz

# Define nul output
VOID = /dev/null

EXT =

## default: Build lib-release and zstd-release
.PHONY: default
default: lib-release zstd-release

.PHONY: all
all: allmost examples

.PHONY: allmost
allmost: allzstd zlibwrapper

# skip zwrapper, can't build that on alternate architectures without the proper zlib installed
.PHONY: allzstd
allzstd: lib
	$(Q)$(MAKE) -C $(PRGDIR) all
	$(Q)$(MAKE) -C $(TESTDIR) all

.PHONY: lib lib-release lib-mt lib-nomt
lib lib-release lib-mt lib-nomt:
	$(Q)$(MAKE) -C $(ZSTDDIR) $@

.PHONY: zstd zstd-release
zstd zstd-release:
	$(Q)$(MAKE) -C $(PRGDIR) $@
	$(Q)ln -sf $(PRGDIR)/zstd$(EXT) zstd$(EXT)

.PHONY: zstdmt
zstdmt:
	$(Q)$(MAKE) -C $(PRGDIR) $@
	$(Q)cp $(PRGDIR)/zstd$(EXT) ./zstdmt$(EXT)

.PHONY: zlibwrapper
zlibwrapper: lib
	$(MAKE) -C $(ZWRAPDIR) all

## test: run long-duration tests
.PHONY: test
DEBUGLEVEL ?= 1
test: MOREFLAGS += -g -Werror
test:
	DEBUGLEVEL=$(DEBUGLEVEL) MOREFLAGS="$(MOREFLAGS)" $(MAKE) -j -C $(PRGDIR) allVariants
	$(MAKE) -C $(TESTDIR) $@
	ZSTD=../../programs/zstd $(MAKE) -C doc/educational_decoder $@

## check: run basic tests for `zstd` cli
.PHONY: check
check:
	$(Q)$(MAKE) -C $(TESTDIR) $@

.PHONY: automated_benchmarking
automated_benchmarking:
	$(MAKE) -C $(TESTDIR) $@

.PHONY: benchmarking
benchmarking: automated_benchmarking

## examples: build all examples in `examples/` directory
.PHONY: examples
examples: lib
	$(MAKE) -C examples all

## man: generate man page
.PHONY: man
man:
	$(MAKE) -C programs $@

.PHONY: clean
clean:
	$(Q)$(MAKE) -C $(ZSTDDIR) $@ > $(VOID)
	$(Q)$(MAKE) -C $(PRGDIR) $@ > $(VOID)
	$(Q)$(MAKE) -C $(TESTDIR) $@ > $(VOID)
	$(Q)$(MAKE) -C $(ZWRAPDIR) $@ > $(VOID)
	$(Q)$(MAKE) -C examples/ $@ > $(VOID)
	$(Q)$(RM) zstd$(EXT) zstdmt$(EXT) tmp*
	@echo Cleaning completed

LIBZSTD_MK_DIR = $(ZSTDDIR)
include $(LIBZSTD_MK_DIR)/install_oses.mk # UNAME, INSTALL_OS_LIST

#------------------------------------------------------------------------------
# make install is validated only for Linux, macOS, Hurd and some BSD targets
#------------------------------------------------------------------------------
ifneq (,$(filter $(INSTALL_OS_LIST),$(UNAME)))

HOST_OS = POSIX

MKDIR ?= mkdir -p

HAVE_COLORNEVER = $(shell echo a | egrep --color=never a > /dev/null 2> /dev/null && echo 1 || echo 0)
EGREP_OPTIONS ?=
ifeq ($(HAVE_COLORNEVER), 1)
EGREP_OPTIONS += --color=never
endif
EGREP = egrep $(EGREP_OPTIONS)

# Print a two column output of targets and their description. To add a target description, put a
# comment in the Makefile with the format "## <TARGET>: <DESCRIPTION>".  For example:
#
## list: Print all targets and their descriptions (if provided)
.PHONY: list
list:
	$(Q)TARGETS=$$($(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null \
		| awk -v RS= -F: '/^# File/,/^# Finished Make data base/ {if ($$1 !~ "^[#.]") {print $$1}}' \
		| $(EGREP) -v  -e '^[^[:alnum:]]' | sort); \
	{ \
	    printf "Target Name\tDescription\n"; \
	    printf "%0.s-" {1..16}; printf "\t"; printf "%0.s-" {1..40}; printf "\n"; \
	    for target in $$TARGETS; do \
	        line=$$($(EGREP) "^##[[:space:]]+$$target:" $(lastword $(MAKEFILE_LIST))); \
	        description=$$(echo $$line | awk '{i=index($$0,":"); print substr($$0,i+1)}' | xargs); \
	        printf "$$target\t$$description\n"; \
	    done \
	} | column -t -s $$'\t'

.PHONY: install
install:
	$(Q)$(MAKE) -C $(ZSTDDIR) $@
	$(Q)$(MAKE) -C $(PRGDIR) $@

.PHONY: uninstall
uninstall:
	$(Q)$(MAKE) -C $(ZSTDDIR) $@
	$(Q)$(MAKE) -C $(PRGDIR) $@

.PHONY: travis-install
travis-install:
	$(MAKE) install PREFIX=~/install_test_dir

.PHONY: clangbuild
clangbuild: clean
	clang -v
	CXX=clang++ CC=clang CFLAGS="-Werror -Wconversion -Wno-sign-conversion -Wdocumentation" $(MAKE) all

.PHONY: cxxtest
cxxtest: CXXFLAGS += -Wall -Wextra -Wundef -Wshadow -Wcast-align -Werror
cxxtest: clean
	$(MAKE) -C $(PRGDIR) all CC="$(CXX) -Wno-deprecated" CFLAGS="$(CXXFLAGS)"   # adding -Wno-deprecated to avoid clang++ warning on dealing with C files directly

regressiontest:
	$(MAKE) -C $(FUZZDIR) regressiontest

uasanregressiontest:
	$(MAKE) -C $(FUZZDIR) regressiontest CC=clang CXX=clang++ CFLAGS="-O3 -fsanitize=address,undefined -Werror" CXXFLAGS="-O3 -fsanitize=address,undefined -Werror"

msanregressiontest:
	$(MAKE) -C $(FUZZDIR) regressiontest CC=clang CXX=clang++ CFLAGS="-O3 -fsanitize=memory -Werror" CXXFLAGS="-O3 -fsanitize=memory -Werror"

update_regressionResults : REGRESS_RESULTS_DIR := /tmp/regress_results_dir/
update_regressionResults:
	$(MAKE) -j -C programs zstd
	$(MAKE) -j -C tests/regression test
	$(RM) -r $(REGRESS_RESULTS_DIR)
	$(MKDIR) $(REGRESS_RESULTS_DIR)
	./tests/regression/test                         \
        --cache  tests/regression/cache             \
        --output $(REGRESS_RESULTS_DIR)/results.csv \
        --zstd   programs/zstd
	echo "Showing results differences"
	! diff tests/regression/results.csv $(REGRESS_RESULTS_DIR)/results.csv
	echo "Updating results.csv"
	cp $(REGRESS_RESULTS_DIR)/results.csv tests/regression/results.csv


# run UBsan with -fsanitize-recover=pointer-overflow
# this only works with recent compilers such as gcc 8+
usan: clean
	$(MAKE) test CC=clang MOREFLAGS="-g -fno-sanitize-recover=all -fsanitize=undefined -Werror $(MOREFLAGS)"

asan: clean
	$(MAKE) test CC=clang MOREFLAGS="-g -fsanitize=address -Werror $(MOREFLAGS)"

asan-%: clean
	LDFLAGS=-fuse-ld=gold MOREFLAGS="-g -fno-sanitize-recover=all -fsanitize=address -Werror $(MOREFLAGS)" $(MAKE) -C $(TESTDIR) $*

msan: clean
	$(MAKE) test CC=clang MOREFLAGS="-g -fsanitize=memory -fno-omit-frame-pointer -Werror $(MOREFLAGS)" HAVE_LZMA=0   # datagen.c fails this test for no obvious reason

msan-%:
	$(MAKE) clean
	LDFLAGS=-fuse-ld=gold MOREFLAGS="-g -fno-sanitize-recover=all -fsanitize=memory -fno-omit-frame-pointer -Werror $(MOREFLAGS)" FUZZER_FLAGS="--no-big-tests $(FUZZER_FLAGS)" $(MAKE) -j -C $(TESTDIR) HAVE_LZMA=0 $*

uasan: clean
	$(MAKE) test CC=clang MOREFLAGS="-g -fno-sanitize-recover=all -fsanitize=address,undefined -Werror $(MOREFLAGS)"

uasan-%: clean
	LDFLAGS=-fuse-ld=gold MOREFLAGS="-g -fno-sanitize-recover=all -fsanitize=address,undefined -Werror $(MOREFLAGS)" $(MAKE) -C $(TESTDIR) $*

tsan-%: clean
	LDFLAGS=-fuse-ld=gold MOREFLAGS="-g -fno-sanitize-recover=all -fsanitize=thread -Werror $(MOREFLAGS)" $(MAKE) -C $(TESTDIR) $* FUZZER_FLAGS="--no-big-tests $(FUZZER_FLAGS)"

.PHONY: c89build gnu90build c99build gnu99build c11build staticAnalyze
c89build: clean
	$(CC) -v
	CFLAGS="-std=c89 -Werror -Wno-attributes -Wpedantic -Wno-long-long -Wno-variadic-macros -O0" $(MAKE) lib zstd

gnu90build: clean
	$(CC) -v
	CFLAGS="-std=gnu90 -Werror -O0" $(MAKE) allmost

c99build: clean
	$(CC) -v
	CFLAGS="-std=c99 -Werror -O0" $(MAKE) allmost

gnu99build: clean
	$(CC) -v
	CFLAGS="-std=gnu99 -Werror -O0" $(MAKE) allmost

c11build: clean
	$(CC) -v
	CFLAGS="-std=c11 -Werror -O0" $(MAKE) allmost

# static analyzer test uses clang's scan-build
# does not analyze zlibWrapper, due to detected issues in zlib source code
staticAnalyze: SCANBUILD ?= scan-build
staticAnalyze:
	$(CC) -v
	CC=$(CC) CPPFLAGS=-g $(SCANBUILD) --status-bugs -v $(MAKE) zstd
endif
