<p align="center"><img src="https://raw.githubusercontent.com/facebook/zstd/dev/doc/images/zstd_logo86.png" alt="Zstandard"></p>

> **Note:** This is an experimental fork of [zstd](https://github.com/facebook/zstd) that is AI-optimized for speed on Apple Silicon (macOS arm64). It is not intended for production use.

__Zstandard__, or `zstd` as short version, is a fast lossless compression algorithm,
targeting real-time compression scenarios at zlib-level and better compression ratios.
It's backed by a very fast entropy stage, provided by [Huff0 and FSE library](https://github.com/Cyan4973/FiniteStateEntropy).

## Build

```bash
cmake -S . -B build-cmake
cmake --build build-cmake
```

Or simply:

```bash
make
```

## License

Zstandard is dual-licensed under [BSD](LICENSE) OR [GPLv2](COPYING).

## Upstream

Based on [facebook/zstd](https://github.com/facebook/zstd).
