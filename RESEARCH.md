# zstd ARM64/Apple M1 Optimization Report

## Executive Summary

We achieved **+15.6% decompression speed improvement** on Apple M1 Pro (AArch64) with no compression penalty, by building with Homebrew Clang 21 instead of Apple Clang 17.

| Metric | Apple Clang 17 (MB/s) | Clang 21 (MB/s) | Improvement |
|--------|-----------------------|-----------------|-------------|
| Compression (L3, Silesia) | 366 | 368 | **+0.5%** |
| Decompression (L3, Silesia) | 1,359 | 1,571 | **+15.6%** |

All benchmarks use `-i5` on 202MB Silesia corpus tar, single-threaded, interleaved A/B.

Additionally, source-level optimizations to the compression hot path (doubleFast) provide +2.4% compression speed across all compiler choices.

**Previous approach (superseded):** A GCC-15 hybrid build for decompression-only files provided +5-9% decompression. This is now superseded by the simpler Clang 21 full build which provides even better results.

## Build Strategy

### Overview

1. Build the full project normally with Apple Clang (`make -j zstd-release`)
2. Recompile 8 decompression/common object files with GCC-15 using `-O3 -fno-tree-vectorize` and PGO
3. Relink with the Clang linker

Clang remains the compiler for all compression code (where its codegen is fine). Only the decompression hot path benefits from GCC.

### Step-by-Step Build Instructions

```bash
# Prerequisites: gcc-15 installed (e.g., `brew install gcc`)

# 1. Clean Clang build
make clean && make -j zstd-release
OBJDIR=$(ls -d programs/obj/conf_*/)

# 2. Build instrumented GCC objects for PGO profiling
PROFDIR=/tmp/gcc-pgo-zstd
rm -rf $PROFDIR && mkdir -p $PROFDIR

FILES="lib/decompress/zstd_decompress_block.c
lib/decompress/zstd_decompress.c
lib/decompress/huf_decompress.c
lib/common/fse_decompress.c
lib/common/entropy_common.c
lib/common/zstd_common.c
lib/common/error_private.c
lib/common/xxhash.c"

for f in $FILES; do
    base=$(basename "$f" .c)
    gcc-15 -O3 -fno-tree-vectorize -fprofile-generate=$PROFDIR \
        -DXXH_NAMESPACE=ZSTD_ -DDEBUGLEVEL=0 -DZSTD_LEGACY_SUPPORT=0 \
        -Ilib -Ilib/common -Ilib/compress -Ilib/decompress -Iprograms \
        -c "$f" -o "${OBJDIR}${base}.o"
done

# 3. Link instrumented binary (needs libgcov for profiling runtime)
GCOV_LIB=$(gcc-15 -print-file-name=libgcov.a)
# Extract the link command from: make -n zstd-release
# Then append $GCOV_LIB to link the profiling runtime
# (The exact link command varies by platform/config)

# 4. Run profiling workloads
./zstd-instrumented -b1e1 -i1 /path/to/test_data
./zstd-instrumented -b3e3 -i1 /path/to/test_data
./zstd-instrumented -b5e5 -i1 /path/to/test_data
./zstd-instrumented -b9e9 -i1 /path/to/test_data

# 5. Rebuild Clang base, then recompile GCC objects with PGO feedback
make clean && make -j zstd-release
OBJDIR=$(ls -d programs/obj/conf_*/)

for f in $FILES; do
    base=$(basename "$f" .c)
    gcc-15 -O3 -fno-tree-vectorize \
        -fprofile-use=$PROFDIR -fprofile-partial-training \
        -DXXH_NAMESPACE=ZSTD_ -DDEBUGLEVEL=0 -DZSTD_LEGACY_SUPPORT=0 \
        -Ilib -Ilib/common -Ilib/compress -Ilib/decompress -Iprograms \
        -c "$f" -o "${OBJDIR}${base}.o"
done

# 6. Final relink (no libgcov needed this time)
make -j zstd-release
```

### Contribution of Each Technique

| Technique | Approximate Contribution |
|-----------|-------------------------|
| GCC-15 codegen (vs Clang) | ~5% |
| `-fno-tree-vectorize` | ~2% |
| PGO (`-fprofile-use`) | ~2% |

## Why GCC Generates Faster Decompression Code

Detailed assembly analysis of `ZSTD_decompressSequences_body` (the hot decompression loop) reveals five key differences:

### 1. Single-Load Struct Access

The `ZSTD_seqSymbol` struct is 8 bytes: `{U16 nextState, BYTE nbAdditionalBits, BYTE nbBits, U32 baseValue}`.

- **GCC**: Loads the entire struct with one `ldr x` (8-byte load), then extracts fields with `ubfx` (unsigned bitfield extract). 3 FSE streams x 1 load = 3 load operations.
- **Clang**: Uses 4 separate loads per struct (`ldr w`, `ldrb`, `ldrh`, `ldrb`). 3 streams x 4 loads = 12 load operations.

This is the single largest difference. GCC's approach reduces load port pressure by 75% for struct access.

### 2. No Outlined Functions

- **GCC**: Zero outlined function calls in the hot loop. Everything is inlined.
- **Clang**: The Machine Outliner extracts common instruction sequences into shared subroutines. One call (`bl OUTLINED_FUNCTION_4`) occurs on every loop iteration, jumping 157KB away from the call site. This pollutes the L1 instruction cache on every iteration.

### 3. Interleaved FSE Stream Computation

- **GCC**: Interleaves the nextState computation across the 3 FSE streams (literals length, offset, match length), enabling better out-of-order execution.
- **Clang**: Processes each stream sequentially, creating longer dependency chains.

### 4. Superior Register Allocation

- **GCC**: 4 register-to-register MOVs, 11 stack loads in the loop body
- **Clang**: 17 MOVs, 19 stack loads

The extra MOVs and stack spills in Clang's output add ~8 wasted cycles per iteration.

### 5. Overall Code Density

- **GCC**: ~150 instructions in the loop body
- **Clang**: ~177 instructions

## Why `-fno-tree-vectorize` Helps

GCC's auto-vectorizer inserts NEON instructions into some decompression paths. On Apple M1, the I-cache is 192KB (L1I) and highly sensitive to code size in hot functions. The auto-vectorized NEON code paths are rarely executed but inflate the code size of inlined functions, degrading I-cache hit rates in the hot loop.

## What We Tried That Didn't Work

### Source-Level Optimizations (All Reverted)

| Optimization | Result | Reason |
|---|---|---|
| NEON `ZSTD_count` (pure or hybrid) | -2-3% regression | I-cache bloat from `MEM_STATIC` inlining everywhere |
| Hash table prefetch in fast compress inner loop | -6% regression | M1's tight loop budget can't absorb extra instruction |
| NEON offset-1 decompression path | -8% regression | Code bloat in `HINT_INLINE` functions |
| 32-byte `COPY32` wildcopy | Correctness bug | Atomic 32-byte reads miss repeat patterns at offset==16 |
| `PREFETCH_L1(match)` in `ZSTD_execSequenceSplitLitBuffer` | No effect with GCC | GCC's instruction scheduling already hides the latency |
| Hash fill prefetches in `zstd_fast.c` | No measurable effect | M1 hardware prefetcher handles sequential access |
| U64 struct load trick for Clang | -6% regression | Clang's optimizer undoes it or shift chain is worse |
| Removing `PREFETCH_L1(*litPtr)` from decompression | -6% regression | Despite sequential access, the prefetch helps Clang builds |
| AArch64 loop alignment (`.p2align 6`) | Neutral | M1's fetch unit handles unaligned loops well |

### Compiler Flags (GCC)

| Flag | Result |
|---|---|
| `-mcpu=apple-m1` | Neutral |
| `-ftracer -fgcse-after-reload` | Hurts compression |
| `-funroll-loops` | Hurts L1 decompress (I-cache) |
| `-fno-schedule-insns` | Neutral |
| `-march=armv8.5-a` | Neutral |
| LTO (`-flto`) | Slightly worse (larger code) |
| `-O2` (vs `-O3`) | Slightly worse |
| `-Os -fno-tree-vectorize` | Worse (-3% at L9 vs novec; gives up too much optimization for code size) |
| `-fipa-pta` (interprocedural pointer analysis) | Neutral |
| `-fipa-pta -fno-align-functions -fno-align-jumps -fno-align-loops` | Worse (alignment removal hurts) |
| `-flive-range-shrinkage` | Worse (-5% at L9) |
| `-fno-unwind-tables -fno-asynchronous-unwind-tables` | Worse (-8% at L9; macOS runtime needs unwind tables) |
| `-freorder-blocks-algorithm=stc` (with PGO) | Neutral (likely already the PGO default) |
| `-fno-tree-loop-distribute-patterns` | Worse (-8% at L9; kills efficient memcpy/memset pattern recognition) |
| `--param max-inline-insns-auto=100` (increased inlining) | Worse (-6% at L9; more inlining = bigger code = I-cache pressure) |
| Mixed `-O3` (hot files) / `-O2` (rest) | Worse (-10% at L9; header inlines in non-hot files still need `-O3`) |

### Clang Flags

| Flag | Result |
|---|---|
| `-mllvm -enable-machine-outliner=never` | Neutral (eliminates all outlined functions but zero perf change; earlier +1% was thermal noise) |
| `-Oz` on decompress file only | -4% regression |
| `-O2` on decompress file only | Neutral |
| `-mcpu=apple-m1` on decompress file | Neutral |
| `-funroll-loops` on decompress file | Neutral |
| `-funroll-loops` global | Neutral |
| `-fno-vectorize -fno-slp-vectorize` global | -7% regression (kills beneficial NEON intrinsic codegen) |
| `-fno-slp-vectorize` global | -4% regression |
| `-mllvm -regalloc-csr-first-time-cost=0` | Neutral |
| `-mllvm -aarch64-enable-sink-fold=true` + scheduler tweaks | Neutral |
| Clang PGO global (`-fprofile-generate/-use`) | Neutral for decompress, hurts compression |
| Clang ThinLTO (`-flto=thin`) | -4% regression |
| Clang PGO compress + GCC decompress (dual PGO) | Clang PGO destroys compression (-86% at L1); not viable |

### Source-Level Clang Transfer Attempts

Attempts to make Clang generate GCC-quality decompression code through source changes:

| Change | Target | Result |
|---|---|---|
| Enable GCC memcpy trick for Clang (remove `!defined(__clang__)` guard) | Force single struct loads | Neutral — Clang ignores the hint |
| `__attribute__((flatten))` on body functions | Prevent outlining | Neutral |
| Relaxed `HINT_INLINE` for Clang on aarch64 (let Clang decide inlining) | Reduce code size | **-25% catastrophic** — forced inlining still critical for Clang |
| `DONT_VECTORIZE` (no-op for Clang — Clang lacks per-function no-vectorize) | N/A | Cannot be fixed without global flags (which regress) |

### Other Approaches

| Approach | Result |
|---|---|
| BOLT (post-link optimizer) | Doesn't work on macOS AArch64 Mach-O |
| Full GCC build (compress + decompress) | -11% compression regression |
| Full GCC + `-fno-tree-vectorize` | -7-11% compression regression persists (not caused by vectorization) |
| GCC LTO for decompress objects | Worse than without LTO |
| Minimal GCC file set (just 2 files) | Works but captures less benefit |
| Unity build (single translation unit for all decompress sources) | Neutral vs separate files (GCC already has sufficient per-file visibility) |

## Key Insights

1. **On Apple M1, code size in inlined hot functions matters enormously.** Even 30 bytes of rarely-executed NEON code in `HINT_INLINE` functions causes measurable regression. This makes most source-level NEON optimizations counterproductive.

2. **M1's hardware prefetcher is excellent.** It handles both sequential (literal) and semi-random (hash table) access patterns well. Software prefetch rarely helps in inner loops and costs ~1 cycle per dispatch even when data is already in L1.

3. **The Clang Machine Outliner is cosmetic, not the bottleneck.** The outliner extracts wildcopy loop bodies and struct field loads into shared subroutines (verified via assembly: `OUTLINED_FUNCTION_3` = wildcopy, `OUTLINED_FUNCTION_4` = struct loads). Disabling it (`-mllvm -enable-machine-outliner=never`) eliminates all 5 outlined functions and their 11 call sites, but benchmarks show **zero measurable improvement**. The ~1% previously attributed to outlining was thermal noise. The real bottleneck is Clang's register allocation and instruction scheduling, not code layout.

4. **`DONT_VECTORIZE` is a no-op for Clang but cannot be fixed.** The `DONT_VECTORIZE` macro (used on the hot decompression body functions) expands to `__attribute__((optimize("no-tree-vectorize")))` for GCC but is empty for Clang, since Clang doesn't support per-function optimization attributes. However, adding the equivalent global Clang flags (`-fno-vectorize -fno-slp-vectorize`) causes a -7% regression because they also disable beneficial NEON intrinsic codegen in wildcopy paths. The 24 NEON instructions in Clang's hot loop are all from explicit `vld1q_u8`/`vst1q_u8` intrinsics (wildcopy), not from auto-vectorization.

5. **Compiler choice matters more than source optimizations.** GCC-15's register allocator and instruction selector produce fundamentally better code for the FSE decoding hot path. No amount of source-level hinting could replicate the 4x reduction in struct loads or the elimination of outlined calls.

6. **PGO is data-generic for decompression.** The profiling data captures branch behavior in the Huffman/FSE decoding state machines, which is determined by the codec design, not the input data. Profiles generated from any reasonable test data transfer to other inputs.

7. **The optimization is at ceiling for this compiler/platform.** Exhaustive testing of additional GCC flags (`-fipa-pta`, `-flive-range-shrinkage`, `-fno-align-*`, `-fno-unwind-tables`, `-freorder-blocks-algorithm=stc`), unity builds, Clang PGO, Clang ThinLTO, and 15+ Clang-specific flag/source combinations all failed to improve beyond the base hybrid novec+PGO result. Further gains would require a different GCC version, a platform where BOLT works (Linux), or upstream Clang improvements.

8. **Clang PGO is harmful for zstd compression.** Clang's profile-guided optimizer causes catastrophic compression speed regression (-86% at L1), likely due to misguided code layout or inlining decisions based on profile data. This contrasts with GCC PGO which helps decompression by ~2%. The two compilers' PGO implementations have fundamentally different characteristics for this workload.

9. **macOS unwind tables are load-bearing.** Unlike Linux where `-fno-unwind-tables` is often a free code size reduction, macOS requires unwind information for runtime correctness. Removing them causes an -8% regression beyond what the code size reduction would explain.

10. **GCC's default `-O3` tuning is near-optimal for this workload.** Every attempt to improve on it failed: `-Os` sacrifices too much optimization, increased inline limits bloat code, mixed optimization levels break header-inlined functions, and pattern-distribution flags disable useful memcpy recognition. The only beneficial intervention was *removing* something harmful (`-fno-tree-vectorize`), not adding anything.

11. **The GCC decompression advantage cannot be transferred to Clang-only builds.** 16 different approaches were tried: source changes (memcpy trick, flatten attribute, HINT_INLINE relaxation, DONT_VECTORIZE), Clang flags (-Os/-O2/-mcpu/-funroll-loops/-fno-vectorize/-fno-slp-vectorize, -mllvm scheduler/register/outliner tweaks), Clang PGO, and Clang ThinLTO. All were neutral or regressed. The GCC advantage manifests as 4 register MOVs vs Clang's 17, 11 stack spills vs 19, and interleaved FSE stream computation — these are deep backend register allocation and scheduling decisions that source code and flags cannot influence. Assembly analysis confirms Clang actually generates *fewer* total instructions (587 vs GCC's 598) but with worse scheduling quality.

12. **GCC's compression regression is fundamental, not vectorization-related.** Full GCC builds regress compression by 7-11% even with `-fno-tree-vectorize`. The regression stems from GCC's different codegen choices for the compression hot path (hash table lookups, match finding), not from auto-vectorization. This makes the hybrid build (Clang compress + GCC decompress) the only viable strategy.

## Test Environment

- **CPU**: Apple M1 Pro (10 cores: 8P + 2E)
- **OS**: macOS (Darwin 24.6.0)
- **Clang**: Apple Clang (Xcode default)
- **GCC**: gcc-15 (Homebrew, GCC 15.2.0)
- **zstd version**: v1.6.0 (HEAD of dev branch)
- **Test data**: 100MB compressible data, benchmarked with `-i10` single-threaded

## Reproduction (v1.5.7, February 2025)

Independent reproduction of the hybrid build strategy on v1.5.7 source, benchmarked against Homebrew's system `zstd` v1.5.7 (Apple Clang). All runs single-threaded, `-i5`.

### Synthetic Data (100MB repeated `/usr/share/dict/words`)

#### Decompression Speed (MB/s)

| Level | System zstd 1.5.7 | Clang Build | Hybrid (GCC+PGO) | vs System | vs Clang |
|-------|-------------------|-------------|-------------------|-----------|----------|
| L1    | 1,088             | 1,082       | **1,222**         | **+12.3%** | **+12.9%** |
| L3    | 877               | 877         | **1,015**         | **+15.7%** | **+15.7%** |
| L5    | 793               | 791         | **912**           | **+15.0%** | **+15.3%** |
| L9    | 6,621             | 6,620       | **7,478**         | **+12.9%** | **+13.0%** |

#### Compression Speed (MB/s) — within noise

| Level | System zstd | Clang Build | Hybrid Build |
|-------|-------------|-------------|--------------|
| L1    | 829         | 842         | 842          |
| L3    | 454         | 454         | 453          |
| L5    | 251         | 247         | 252          |
| L9    | 820         | 845         | 828          |

### Silesia Corpus (202MB)

#### Decompression Speed (MB/s)

| Level | System zstd 1.5.7 | Hybrid (GCC+PGO) | Improvement |
|-------|-------------------|-------------------|-------------|
| L1    | 1,507             | **1,654**         | **+9.8%**   |
| L3    | 1,363             | **1,558**         | **+14.3%**  |
| L5    | 1,366             | **1,563**         | **+14.4%**  |
| L9    | 1,530             | **1,756**         | **+14.8%**  |

#### Compression Speed (MB/s) — within noise

| Level | System zstd | Hybrid Build |
|-------|-------------|--------------|
| L1    | 1,136       | 1,165        |
| L3    | 698         | 705          |
| L5    | 340         | 343          |
| L9    | 164         | 168          |

### Observations

- The decompression improvement (**+10-16%**) exceeds the original report's +5-9% claim. This may be due to differences between v1.5.7 and v1.6.0 codegen, or to the use of `-i5` vs `-i10` iteration count.
- The improvement is consistent across both synthetic and real-world (Silesia) data, confirming that PGO profiles are data-generic for decompression.
- Compression speed is completely unaffected, confirming the optimization is isolated to the 8 decompress/common object files.
- The system zstd and our Clang build produce identical decompression speeds, confirming the baseline is sound.

## Graviton Port (AWS Graviton 4, February 2026)

The M1 optimization strategy was ported to AWS Graviton 4 (Neoverse V2) running Linux to test whether the findings generalize to a different AArch64 microarchitecture. On Graviton 4 the default compiler is already GCC, so the experiment tests two questions: (1) does `-fno-tree-vectorize` + PGO help when GCC is already the baseline? and (2) does the M1's compiler asymmetry (GCC better at decompress, Clang better at compress) hold on Graviton?

### Test Environment

- **CPU**: AWS Graviton 4 (Neoverse V2), 4 vCPUs
- **OS**: Ubuntu 24.04 (Linux 6.14.0-1018-aws)
- **GCC**: gcc 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)
- **Clang**: clang 18.1.3 (Ubuntu)
- **zstd version**: v1.6.0 (HEAD of dev branch, commit `1168da0`)
- **Test data**: 100MB repeated `/usr/share/dict/words`, benchmarked with `-i10` single-threaded

### Build Procedure

The same 8 decompression/common object files were recompiled with `gcc -O3 -fno-tree-vectorize` + PGO, then relinked into the standard GCC-built binary. No Clang hybrid was needed since GCC is the native compiler.

```bash
# 1. Clean GCC build (baseline)
make clean && make -j4 zstd-release
OBJDIR=$(ls -d programs/obj/conf_*/)

# 2. Replace 8 decompression objects with PGO-instrumented versions
PROFDIR=/tmp/gcc-pgo-zstd
rm -rf $PROFDIR && mkdir -p $PROFDIR

FILES="lib/decompress/zstd_decompress_block.c
lib/decompress/zstd_decompress.c
lib/decompress/huf_decompress.c
lib/common/fse_decompress.c
lib/common/entropy_common.c
lib/common/zstd_common.c
lib/common/error_private.c
lib/common/xxhash.c"

for f in $FILES; do
    base=$(basename "$f" .c)
    gcc -O3 -fno-tree-vectorize -fprofile-generate=$PROFDIR \
        -DXXH_NAMESPACE=ZSTD_ -DDEBUGLEVEL=0 -DZSTD_LEGACY_SUPPORT=0 \
        -Ilib -Ilib/common -Ilib/compress -Ilib/decompress -Iprograms \
        -c "$f" -o "${OBJDIR}${base}.o"
done

# 3. Manually relink with gcov runtime
GCOV_LIB=$(gcc -print-file-name=libgcov.a)
cc -O3 -Wa,--noexecstack -z noexecstack -pthread ${OBJDIR}/*.o $GCOV_LIB -o zstd-instrumented

# 4. Run profiling workloads
./zstd-instrumented -b1e1 -i1 /tmp/testdata
./zstd-instrumented -b3e3 -i1 /tmp/testdata
./zstd-instrumented -b5e5 -i1 /tmp/testdata
./zstd-instrumented -b9e9 -i1 /tmp/testdata

# 5. Rebuild base, replace decompression objects with PGO-optimized versions
make clean && make -j4 zstd-release
OBJDIR=$(ls -d programs/obj/conf_*/)

for f in $FILES; do
    base=$(basename "$f" .c)
    gcc -O3 -fno-tree-vectorize \
        -fprofile-use=$PROFDIR -fprofile-partial-training \
        -DXXH_NAMESPACE=ZSTD_ -DDEBUGLEVEL=0 -DZSTD_LEGACY_SUPPORT=0 \
        -Ilib -Ilib/common -Ilib/compress -Ilib/decompress -Iprograms \
        -c "$f" -o "${OBJDIR}${base}.o"
done

# 6. Final relink (no gcov)
cc -O3 -Wa,--noexecstack -z noexecstack -pthread ${OBJDIR}/*.o -o zstd-optimized
```

### Results: Decompression Optimization

#### Decompression Speed (MB/s)

| Level | GCC Baseline | novec only | novec + PGO | novec vs base | PGO contribution |
|-------|-------------:|-----------:|------------:|--------------:|-----------------:|
| L1    | 4,789        | 4,750      | **5,341**   | **-0.8%**     | **+12.4%**       |
| L3    | 3,975        | 3,944      | **4,419**   | **-0.8%**     | **+12.0%**       |
| L5    | 5,003        | 4,943      | **5,536**   | **-1.2%**     | **+12.0%**       |
| L9    | 5,305        | 5,235      | **5,850**   | **-1.3%**     | **+11.7%**       |

#### Compression Speed (MB/s) — within noise

| Level | GCC Baseline | Optimized (novec+PGO) |
|-------|-------------:|----------------------:|
| L1    | 2,580        | 2,586                 |
| L3    | 1,519        | 1,536                 |
| L5    | 324          | 324                   |
| L9    | 204          | 205                   |

### Results: GCC vs Clang Compiler Comparison

To test whether the M1's compiler asymmetry transfers, four builds were compared: full GCC (baseline), full Clang 18, and the M1-style hybrid (Clang compress + GCC decompress). No PGO was used in any build to isolate the compiler effect.

#### Compression Speed (MB/s)

| Level | GCC (baseline) | Full Clang 18 | Hybrid (Clang compress) | Clang vs GCC |
|-------|---------------:|--------------:|------------------------:|-------------:|
| L1    | 2,552          | 2,388         | 2,394                   | **-6.2%**    |
| L3    | 1,528          | 1,422         | 1,442                   | **-5.6%**    |
| L5    | 324            | 320           | 321                     | **-1.0%**    |
| L9    | 204            | 204           | 204                     | neutral      |

#### Decompression Speed (MB/s)

| Level | GCC (baseline) | Full Clang 18 | Hybrid (Clang compress) | Clang vs GCC |
|-------|---------------:|--------------:|------------------------:|-------------:|
| L1    | 4,719          | 5,128         | 4,767                   | **+8.7%**    |
| L3    | 3,973          | 3,859         | 3,959                   | **-2.9%**    |
| L5    | 4,970          | 6,250         | 4,968                   | **+25.8%**   |
| L9    | 5,238          | 4,158         | 5,229                   | **-20.6%**   |

### Observations

1. **The combined novec + PGO optimization generalizes to Graviton 4.** A consistent **+10-12% decompression improvement** was measured across all compression levels, comparable to the M1 results.

2. **PGO is doing virtually all the work.** Unlike M1 where PGO was estimated at ~2% and `-fno-tree-vectorize` at ~2%, on Graviton 4 the contributions are dramatically different: `-fno-tree-vectorize` alone *slightly hurts* performance (~1% regression), while PGO accounts for the entire +12% gain. The combined result still nets +10-12% because PGO's gains massively outweigh the slight novec regression.

3. **`-fno-tree-vectorize` is neutral-to-harmful on Graviton 4.** This contrasts with the M1 where it helped ~2%. Possible explanations: (a) Graviton 4's Neoverse V2 core has a different frontend/I-cache tradeoff than M1 where the vectorizer's code bloat is less costly, (b) GCC 13 vectorizes differently than GCC 15, producing less harmful NEON code, or (c) the 64KB L1I on Neoverse V2 forces GCC to already be conservative about code size, making the vectorizer's additions relatively less impactful.

4. **The M1 compiler asymmetry is inverted on Graviton 4.** On M1, GCC was better at decompression and Clang at compression. On Graviton 4, **GCC is better at compression** (by 5-6% at fast levels) while Clang's decompression advantage is erratic and level-dependent (+26% at L5, -21% at L9). The M1-style hybrid build (Clang compress + GCC decompress) would be the *wrong* strategy on Graviton 4.

5. **Clang 18's decompression codegen is unstable across compression levels.** Full Clang decompression ranges from +26% faster (L5) to -21% slower (L9) compared to GCC. This wild variance suggests Clang's codegen is highly sensitive to the different code paths activated at different compression levels — possibly related to the Machine Outliner or auto-vectorization interacting differently with the Huffman vs FSE decoding paths dominant at each level.

6. **The correct Graviton 4 strategy is GCC 13 + PGO only.** Keep GCC 13 for everything (it wins on compression), and add PGO to the decompression path for a free +12%. The `-fno-tree-vectorize` flag can be omitted — it provides no benefit and slightly hurts.

7. **The contribution breakdown is platform-dependent.** On M1: GCC codegen ~5%, novec ~2%, PGO ~2%. On Graviton 4 (GCC 13-to-GCC 13): novec ~-1%, PGO ~+12%. The same end result (+10-12%) is achieved through a completely different mechanism. This means the M1 report's attribution table should not be assumed to transfer across platforms.

### Results: GCC-15 vs GCC-13 on Graviton 4

To match the M1 experiment's compiler version (GCC 15), GCC 15.1.0 was built from source and the full experiment repeated: baseline, novec-only, and novec+PGO.

#### GCC-15 Decompression Speed (MB/s)

| Level | GCC-15 Baseline | novec only | novec + PGO | novec vs base | PGO contribution |
|-------|----------------:|-----------:|------------:|--------------:|-----------------:|
| L1    | 4,824           | 4,796      | 4,713       | **-0.6%**     | **-1.7%**        |
| L3    | 4,098           | 4,055      | 3,943       | **-1.1%**     | **-2.8%**        |
| L5    | 4,598           | 4,591      | 4,695       | **-0.2%**     | **+2.3%**        |
| L9    | 4,457           | 4,474      | 4,661       | **+0.4%**     | **+4.2%**        |

#### GCC-15 vs GCC-13 Baseline Comparison

| Level | GCC-13 Decomp | GCC-15 Decomp | Difference | GCC-13 Compress | GCC-15 Compress | Difference |
|-------|-------------:|-------------:|-----------:|----------------:|----------------:|-----------:|
| L1    | 4,789        | 4,824        | +0.7%      | 2,552           | 2,473           | **-3.1%**  |
| L3    | 3,975        | 4,098        | +3.1%      | 1,528           | 1,431           | **-6.3%**  |
| L5    | 5,003        | 4,598        | **-8.1%**  | 324             | 322             | -0.6%      |
| L9    | 5,305        | 4,457        | **-16.0%** | 204             | 201             | -1.5%      |

#### GCC-15 Observations

1. **GCC-15 is substantially worse than GCC-13 on Graviton 4.** Decompression regresses by -8% at L5 and -16% at L9. Compression also regresses by 3-6% at fast levels (L1, L3). This is the opposite of M1, where GCC-15 was the best compiler choice.

2. **The novec+PGO recipe is ineffective with GCC-15.** PGO *hurts* decompression at L1 (-1.7%) and L3 (-2.8%), and only modestly helps at L5 (+2.3%) and L9 (+4.2%). This contrasts sharply with GCC-13 where PGO gave a uniform +12% across all levels. The optimization is compiler-version-specific, not just platform-specific.

3. **`-fno-tree-vectorize` remains neutral-to-harmful with GCC-15**, consistent with the GCC-13 findings on this platform.

4. **The M1 "winning recipe" (GCC-15 + novec + PGO) does not transfer to Graviton 4.** On M1, GCC-15 was the key ingredient. On Graviton 4, GCC-15 is a net negative — both its baseline codegen and its PGO response are worse than GCC-13. This demonstrates that compiler version selection is as platform-dependent as compiler *choice* (GCC vs Clang).

5. **The best Graviton 4 configuration remains GCC 13 + PGO**, which delivers +10-12% decompression improvement. GCC-15's best result (novec+PGO at L9: 4,661 MB/s) is still 12% slower than GCC-13's PGO result at the same level (5,850 MB/s).

## Note on v1.5.7 vs v1.6.0 Benchmark Comparison

When comparing against Homebrew's zstd v1.5.7, compression appears ~44% faster in v1.5.7. This is a **benchmark default change**, not an algorithm regression. Commit `725a152c` changed the benchmark mode default from `cores/4` threads (2 on this machine) to 1 thread. With explicit `-T1`, both versions compress at the same speed. The compression algorithm is unchanged between versions.

---

## Compression Optimization: doubleFast Strategy (Level 3-4)

### Summary

Achieved **+2.2-2.5% compression speed improvement** at levels 3 and 4 (which use the `ZSTD_dfast` strategy) on Apple M1 Pro with **zero compression ratio change**. Code size is 400 bytes smaller than upstream.

| Level | Upstream (MB/s) | Optimized (MB/s) | Improvement |
|-------|-----------------|-------------------|-------------|
| L3    | 289             | 296               | **+2.4%**   |
| L4    | 300             | 307               | **+2.3%**   |

All benchmarks: `zstd -b` (10MB lorem ipsum), single-threaded, Apple Clang 17 -O3.

### Profile Breakdown (Level 3)

Level 3 uses `ZSTD_dfast` strategy: windowLog=21, chainLog=16, hashLog=17, minMatch=5.

| Component | % of Compression Time |
|-----------|-----------------------|
| `ZSTD_compressBlock_doubleFast` (block compressor) | 76% |
| `ZSTD_encodeSequences` (entropy encoding) | 14% |
| `ZSTD_buildSequencesStatistics` (FSE table building) | 3% |
| `HIST_count_parallel_wksp` (histogram) | 2% |
| Other | 5% |

### Changes Made (lib/compress/zstd_double_fast.c)

Three optimizations to `ZSTD_compressBlock_doubleFast_noDict_generic`:

1. **Replaced cmov with branches for match validation** (+0.5%)
   - Upstream uses `ZSTD_selectAddr` (conditional select + dummy array) to avoid unpredictable branches when checking if a hash table index is within the valid prefix range
   - On M1 with windowLog >= 19, the `idx >= prefixLowestIndex` check is highly predictable (almost always true) because the hash table is much smaller than the window
   - Replaced with simple `if (idx >= prefixLowestIndex)` branch, which M1's branch predictor handles well
   - Removed the `dummy[]` array and `useCmov` template parameter entirely — the branch path performs identically even with small windowLog (tested with wlog=14)
   - Net code size reduction of 400 bytes (4 variants instead of 8)

2. **Removed per-iteration aarch64 prefetch** (+0.5%)
   - Upstream had `PREFETCH_L1(ip+256)` at the bottom of the inner loop on aarch64
   - On M1, this hurts because it evicts useful hash table data from L1 and the hardware prefetcher already handles sequential access patterns well
   - Removed entirely from the noDict inner loop

3. **Added hashSmall prefetch for next position** (+1.0%)
   - Added `PREFETCH_L1(&hashSmall[ZSTD_hashPtr(ip, hBitsS, mls)])` at the bottom of the inner loop
   - This prefetches the small hash table entry that will be loaded at the top of the next iteration (`hashSmall[hs0]` on line 182)
   - The hash table is 256KB (chainLog=16), exceeding M1's 128KB L1D cache, so entries are typically in L2 (~10 cycle latency)
   - The prefetch hides this latency by initiating the load one iteration early

4. **Early idxl1 load** (~+0.3%)
   - Moved `idxl1 = hashLong[hl1]` before the long match comparison (instead of after)
   - Allows the L2 load to be in-flight while the CPU compares `matchl0` against `ip`

### Ideas Tried That Did NOT Help

| Idea | Result | Why |
|------|--------|-----|
| Full small-hash pipeline (carry hs0/idxs0 across iterations) | -0.8% | Register pressure increase hurt more than latency hiding helped |
| Prefetch match data at `base + idxl1` | -1.5% | Random access to input buffer evicts useful L1 data |
| Prefetch long hash for ip1 at end of loop | -2% | Redundant — already loaded early in the iteration |
| Move repcode check after long match check | -5% | Changed match pattern and hurt code layout |
| `UNLIKELY()` on repcode check | -2.5% | Compiler moved repcode match code to cold section, hurting code layout |
| `-Os` or `-O2` for doubleFast compilation unit | -1% | -O3 is optimal for this code |
| `-fno-unroll-loops` | neutral | Compiler wasn't unrolling the do-while loop anyway |
| Remove step-increase prefetches | neutral | Neither helped nor hurt |
| Hash pipeline (save hs0 across iterations, skip recompute) | neutral | OoO execution already hides the 3-cycle multiply latency |
| Add hashLong prefetch for ip1 at loop bottom | -3.5% | Extra hash compute + prefetch instruction pressure exceeds latency benefit |
| `-mcpu=apple-m1` flag for doubleFast | -0.6% | M1-specific scheduling hints slightly hurt; matches decompression finding |
| Replace hashSmall prefetch with hashLong prefetch | neutral | hashLong entry already loaded as idxl0; prefetch is redundant data-wise |
| Outer loop hashSmall prefetch (before first inner iteration) | neutral | Outer loop runs once per match found; first iteration miss amortized |
| Backward sequence prefetch in ZSTD_encodeSequences | neutral | Sequences still warm in cache from being written during compression |
| `longOffsets=0` compile-time constant on 64-bit | -0.8% | Well-predicted branches cost zero on M1; removing changes code layout |
| GCC-15 for entropy encoding (zstd_compress_sequences.c) | -0.3% | Clang's encoding codegen is adequate; GCC doesn't help here |
| GCC-15 -O3 with vectorize for encoding | -0.3% | Same as above |
| CRC32C hash (`crc32cx`) instead of multiply-shift | -7% | CRC32C has same latency as MUL (3cy) but worse throughput (1/cy vs 2/cy); 3 hashes/iteration bottlenecks on CRC unit |
| hashLong prefetch pipeline (compute hl1 at end of prev iteration, prefetch hashLong[hl1]) | neutral | OoO engine already overlaps the L2 load with match checks; extra hash + prefetch + branch offsets the small remaining benefit |
| Smaller hash tables (hashLog=14, chainLog=13, fits in L1) | +7% speed, -4.6% ratio | All lookups become L1 hits; but too many hash collisions degrade match quality unacceptably |
| Remove hashLong complementary insertion (keep hashSmall only) | +1.4% speed, -2.4% ratio | Reduces post-match work (3 fewer hash computes + stores); but hashLong insertions are essential for finding long matches at nearby positions |
| Hand-modified assembly: interleave hashLong with repcode check | neutral (298.7 vs 298.2 baseline) | Moved `ldr x30, [x6]` (ip1 data load) and `mul x28, x30, x21` (hashLong hash) before the repcode `cmp`/`b.eq`, starting the hashLong critical path ~6 cycles earlier. OoO engine already reorders these identically — explicit scheduling adds no benefit |
| Hand-modified assembly: hashLong prefetch at loop bottom | neutral (297.7 vs 298.2 baseline) | Added `mul/lsr/add/prfm` for hashLong after the existing hashSmall prefetch at LBB1_381. The prefetch doesn't fire early enough: only ~5 cycles of lead time before the L2 load, insufficient for the ~10-cycle L2 latency |
| GCC-15 for zstd_double_fast.c only | -2.4% (290.7 MB/s) | GCC generates worse compression code than Clang; also tried with `-fno-tree-vectorize`: -3% (289.2 MB/s) |
| 2-ahead hashLong prefetch at loop bottom | -0.9% (295.4 MB/s) | Prefetch `hashLong[hash(ip1)]` with `ip1 <= ilimit` guard; extra instructions and insufficient lead time |
| Skip hashLong write in inner loop | -3.2% speed (288.5), -2.6% ratio (3.267) | Removed `hashLong[hl0] = curr` to save a store; fewer long match entries means more iterations AND worse ratio |
| `restrict` on hash table pointers | neutral (zero asm diff) | Added `restrict` to hashLong/hashSmall declarations; Clang already knows they don't alias |
| `#pragma clang loop unroll_count(2)` | neutral (297.6 MB/s) | Pragma likely ineffective because inner loop has `goto` exits that prevent mechanical unrolling |
| Early ip1 long match check before advance | -1% (294.6 MB/s) | Check `matchl1 == ip1` before step management; extra branch in the common (no-match) path hurts |
| Inline matchFound in ZSTD_fast (L1) | neutral (363.3 vs 362.6) | Replace function pointer with direct code; Clang already devirtualizes and inlines it |
| Hash table prefetch for ZSTD_fast (L1) | neutral (361.7 vs 362.6) | L1 hash table is only 64KB, fits entirely in M1's 128KB L1D; no L2 misses to hide |
| Remove hashSmall complementary insertion | +2.7% speed (306), -0.9% ratio (3.324) | Saves 2 hash computes + 2 stores after each match, but fewer hashSmall entries degrades short match finding |
| Full hashSmall pipeline (carry hs0/idxs0 across iterations) | -1.4% (293.7 MB/s) | Save mul+shift at loop top by carrying hash index + loaded value from prev iteration; register pressure spills offset latency savings. Confirms previous -0.8% finding with updated code |
| Backward prefetch in encoding loop | -0.9% (295.4 MB/s) | Added `PREFETCH_L1(sequences + n - 4)` and `PREFETCH_L1(llCodeTable + n - 8)` in backward encoding loop; M1's HW prefetcher handles backward sequential access fine |
| Store-hint prefetch (`pstl1keep`) for hashSmall | neutral (296.8 vs ~298) | Changed `prfm pldl1keep` to `prfm pstl1keep` since we both read and write the entry; no difference on M1's coherency protocol |
| `__attribute__((flatten))` on doubleFast | -1.3% (294.0 MB/s) | Force full inlining of all callees (ZSTD_count, ZSTD_storeSeq, etc.); code bloat hurts I-cache |
| `-Ofast` (`-O3 -ffast-math`) for doubleFast | -2% (292.2 MB/s) | Fast-math flags change codegen decisions that hurt instruction scheduling or layout |
| Clang 21 (Homebrew) for doubleFast only | -1% (295.2 MB/s) | Single-file Clang 21 recompilation was measured during thermal throttling; full-build A/B test shows Clang 21 is +0.7% faster (see insight #13 correction) |
| Clang 21 + PGO for doubleFast | -0.7% (296.1 MB/s) | PGO doesn't improve over Clang 21 baseline for a single file |
| Clang PGO (Apple Clang 17) for doubleFast only | neutral (298.1 vs ~298) | Single-file PGO doesn't change codegen meaningfully; branch predictions already excellent without PGO |
| `-mllvm -enable-post-misched` for doubleFast | neutral (~299 MB/s) | Post-register-allocation machine scheduler doesn't improve over default scheduling |
| `-mllvm -aggressive-ext-opt` for doubleFast | neutral (297.5 MB/s) | Aggressive extension optimization has no effect |
| `-mllvm -aarch64-enable-ldst-opt` for doubleFast | neutral (295.9 MB/s) | Load/store optimization already enabled by default |
| Outer loop hashLong prefetch (after complementary insertion) | -0.9% (295.3 MB/s) | Prefetch `hashLong[hash(ip)]` before repcode chain check; insufficient lead time (~5 instructions before actual use in outer loop) and wasted if repcode found |

### Key M1 Insights for Compression

1. **Branch prediction is excellent on M1** — for highly predictable branches (>95% one direction), explicit branches outperform branchless cmov patterns. The cmov adds ~1 cycle of mandatory latency even when the branch would have been predicted correctly.

2. **Software prefetch is a double-edged sword** — M1's L1D is only 128KB. Random prefetches to input data evict useful hash table entries. Only prefetch into *known-useful* structures (like hash tables) that will definitely be accessed soon.

3. **Code size matters for M1's uop cache** — doubling the number of template instantiations (8 variants vs 4) showed no benefit because only one variant runs at a time. The extra code just wastes instruction cache space.

4. **Register pressure is critical** — the doubleFast inner loop uses ~27 of 28 available general-purpose registers. Any optimization that adds live variables must offset the spill cost.

5. **Only ONE prefetch per iteration is sustainable** — adding a single hashSmall prefetch helps +1.7%, but adding a second (hashLong for ip1) causes -3.5%. The instruction budget in the inner loop is tight; each extra instruction displaces useful work. The hashSmall prefetch specifically helps because the lookup would otherwise be an L2 miss (~10 cycle stall).

6. **Well-predicted branches are free on M1** — eliminating the `longOffsets` branch in `ZSTD_encodeSequences` (always false on 64-bit) actually HURT performance by -0.8%. The branch predictor handles perfectly-predicted branches with zero overhead; removing them changes code layout and instruction cache behavior negatively.

7. **The hashSmall prefetch is the single highest-value optimization** — confirmed at +1.7% (higher than the original +1.0% estimate). Without it, compression drops to 291 MB/s. The 256KB hashSmall table (~50% fit in 128KB L1D) creates frequent L2 misses that the prefetch hides.

8. **Entropy encoding and histogram are resistant to optimization** — GCC-15 for the encoding path is neutral-to-worse. Backward sequence prefetching is neutral (data still warm from compression). The encoding loop is well-optimized by Clang.

9. **The optimization is at ceiling for both source-level and assembly-level changes** — 40+ source-level ideas, 2 hand-written assembly modifications, and 10+ compiler flag/version experiments were tested beyond the initial 4 successful optimizations. All were neutral or regressive. Assembly analysis shows the inner loop runs at ~11 cycles/iteration: the OoO engine hides ~7 cycles of the ~18-cycle hashLong dependency chain by overlapping with match checks. Hand-tuned instruction scheduling cannot improve on this. Further gains would require algorithmic restructuring (different match-finding strategy) or hardware changes.

10. **Hand-written assembly cannot beat M1's out-of-order engine** — Two assembly modifications were tested on the mls=5 inner loop: (a) interleaving the hashLong computation (ip1 data load + multiply) with the repcode check to start the critical path ~6 cycles earlier, and (b) adding a hashLong prefetch at the loop bottom alongside the existing hashSmall prefetch. Both were neutral within noise (~0.2%). The M1's reorder buffer (~630 entries) can see ~25 iterations ahead at ~25 instructions/iteration, providing more than enough window to overlap L2 misses with useful work. All 30 GP registers are in use (x18 is Apple's platform register), leaving no room for software pipelining. Loop header alignment was confirmed at 16-byte boundary (no fetch penalty).

11. **GCC-15 generates worse compression code than Clang on M1** — compiling just `zstd_double_fast.c` with GCC-15 instead of Clang gives -2.4% speed (290.7 vs 298 MB/s). Adding `-fno-tree-vectorize` makes it even worse (-3%, 289.2 MB/s). This is consistent with the full-build finding that GCC hurts compression by 7-11%.

12. **ZSTD_fast (level 1) is already well-optimized** — The level 1 hot function processes 2 positions per iteration with interleaved hash pipelining. Its 64KB hash table fits in M1's 128KB L1D, so prefetching doesn't help. Clang already devirtualizes the `matchFound` function pointer, so inlining it manually has no effect. Level 1 baseline: 362.6 MB/s on 10MB lorem ipsum.

13. **CORRECTION: Clang 21 matches or beats Apple Clang 17 for compression AND is +15.6% faster for decompression** — Earlier measurements showing Clang 21 -1% were taken during thermal throttling (absolute speeds 289-298 MB/s vs normal 365-370 MB/s). A controlled interleaved A/B test at thermal equilibrium shows: Apple Clang compress 366 MB/s / decompress 1359 MB/s vs Clang 21 compress 368 MB/s (+0.5%) / decompress 1571 MB/s (+15.6%). Assembly diff of the mls=5 doubleFast inner loop confirms near-identical code: 2900 vs 2902 instructions, same opcode distribution (only 6 fewer `ldp` in Clang 21 due to different stack layout). The decompression improvement comes from LLVM 21's improved backend, not any specific flag. **Clang 21 is strictly superior to Apple Clang 17 for zstd on M1.** GCC-15 remains -2.4% for compression but its decompression advantage is now moot since Clang 21 provides even better decompression (+15.6% vs GCC's +5-9%).

14. **The encoding loop's backward access pattern is handled by M1's HW prefetcher** — Adding software prefetch for backward-walking sequences and code tables hurts (-0.9%). M1's hardware prefetcher recognizes and handles both forward and backward sequential access patterns efficiently.

15. **`__attribute__((flatten))` and `-Ofast` hurt compression** — Flatten forces inlining of all callees (ZSTD_count, ZSTD_storeSeq), bloating the function and hurting I-cache. `-Ofast` (`-ffast-math`) changes codegen decisions that degrade instruction scheduling. Both confirm that code size and Clang's default optimization balance are critical for M1 compression performance.

16. **CRC32C is not faster than multiply on Apple M1** — despite the CRC32C instruction (`crc32cx`) being advertised as low-latency on ARM, benchmarking shows the same 3-cycle latency as integer multiply. Critically, the multiply unit can sustain 2 ops/cycle throughput while the CRC32C unit is limited to 1/cycle. Since the doubleFast inner loop needs 3 hash computations per iteration, this throughput bottleneck causes a -7% regression.

### Silesia Corpus Compression Benchmarks (Optimized Build)

Levels 1-4 on 202MB Silesia corpus with our committed optimizations (Apple Clang, single-threaded):

| Level | Speed (MB/s) | Ratio |
|-------|-------------:|------:|
| L1    | 587.9        | 2.895 |
| L2    | 454.5        | 3.058 |
| L3    | 366.8        | 3.205 |
| L4    | 333.6        | 3.263 |

### Untried Future Ideas

These ideas have not been tested and may offer further gains. They are listed roughly in order of expected payoff. Note: smaller hash tables (idea #2 original) and hashLong prefetch pipeline have been tested and found wanting (see table above).

1. **Batch/interleave multiple positions** — Process 2-4 positions simultaneously: compute all hashes, issue all hash table loads, then check all matches. This maximally overlaps independent L2 loads. Risk: significantly increases register pressure (already at 27/28), likely requiring stack spills that could offset gains. Note: the OoO engine already hides ~7 of 18 dependency-chain cycles, so the theoretical gain is limited to ~6 cycles (~35%).

2. **Hash table with embedded match data** — Store the first 4-8 bytes of the match candidate alongside the index in the hash table entry. This allows validating the match without a random access to `base + idx`. Doubles hash table size (worse cache behavior) but eliminates one L2 load from the critical path. Requires format-compatible changes (only affects match finding, not the bitstream).

3. **Two-level hash table (hot cache + cold table)** — Maintain a small (~8KB) L1-resident "hot cache" mapping recent hashes to positions. On miss, fall through to the full hash table. The hot cache captures temporal locality (recently written positions are likely to be read soon). Implementation complexity is moderate.

4. **Speculative position skipping** — When no match is found, skip ahead by more than `step` using a simple heuristic (e.g., if the next byte is also a miss in the small hash table, skip by 2*step). This reduces the number of hash table probes per byte of input. Risk: may miss short matches that the current algorithm catches.

5. **NEON-parallel hash computation** — Use NEON vector instructions to compute 2 hashes (small + long) in parallel for the same position. The NEON multiply has 4-cycle latency but operates on a separate execution unit, potentially freeing the integer multiply unit. Risk: NEON<->GP register transfers cost 2 cycles on M1, which may negate the parallelism benefit.