This is an experimental fork of [zstd](https://github.com/facebook/zstd) that is AI-optimized for speed on Apple Silicon (macOS arm64). It is not intended for production use.

## Install

```bash
brew tap vibekernels/tap
brew install zstd-vk
```

## Build from source

```bash
brew install llvm
make CC=$(brew --prefix llvm)/bin/clang
```

## License

Zstandard is dual-licensed under [BSD](LICENSE) OR [GPLv2](COPYING).

## Upstream

Based on [facebook/zstd](https://github.com/facebook/zstd).
