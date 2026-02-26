This is an experimental fork of [zstd](https://github.com/facebook/zstd) that is AI-optimized for speed on Apple Silicon (macOS arm64). It is not intended for production use.

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
