# CC Streamer

[![CI](https://github.com/dmuso/ccstreamer/actions/workflows/ci.yml/badge.svg)](https://github.com/dmuso/ccstreamer/actions/workflows/ci.yml)
[![Release](https://github.com/dmuso/ccstreamer/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/dmuso/ccstreamer/actions/workflows/build-and-release.yml)
[![License](https://img.shields.io/github/license/dmuso/ccstreamer)](LICENSE)

CC Streamer is a CLI app that accepts streamed JSON output from Claude Code and formats it for your terminal so it's nice and easy to read.

## Example Ouput

### Before CC Streamer

![Before CC Streamer](https://github.com/dmuso/ccstreamer/blob/master/docs/before-ccstreamer.png)

### After CC Streamer

![After CC Streamer](https://github.com/dmuso/ccstreamer/blob/master/docs/after-ccstreamer.png)

## Installation

### Download Pre-built Binaries

Download the latest release for your platform from the [Releases page](https://github.com/dmuso/ccstreamer/releases).

#### Linux/macOS
```bash
# Download and extract (replace <platform> and <version> with actual values)
tar -xzf ccstreamer-<platform>-<version>.tar.gz

# Make executable and move to PATH
chmod +x ccstreamer
sudo mv ccstreamer /usr/local/bin/
```

#### Windows
1. Download the Windows zip file from the releases page
2. Extract `ccstreamer.exe`
3. Add to your PATH or move to a directory in your PATH

### Build from Source

Requirements:
- Zig 0.14.1 or later

```bash
git clone https://github.com/dmuso/ccstreamer.git
cd ccstreamer
zig build -Doptimize=ReleaseSafe

# Binary will be in zig-out/bin/ccstreamer
sudo cp zig-out/bin/ccstreamer /usr/local/bin/
```

## Using CC Streamer

```bash
PROMPT="Build me a hello world app in C"

claude --verbose -p --output-format stream-json --dangerously-skip-permissions "$PROMPT" | ccstreamer
```


## Development

### Running Tests

```bash
# Run all tests
zig build test

# Run with specific optimization
zig build test -Doptimize=Debug
```

### Building for Different Platforms

```bash
# Linux x86_64
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe

# macOS x86_64 (Intel)
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe

# macOS ARM64 (Apple Silicon)
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe

# Windows x86_64
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

### Creating a Release

```bash
# Bump version and create release tag
./scripts/release.sh patch  # or minor/major

# Push to trigger automated release
git push origin master
git push origin v0.1.0  # Replace with your version
```

## CI/CD

This project uses GitHub Actions for continuous integration and deployment:

- **CI**: Runs on every push and PR, includes tests, formatting checks, and multi-platform builds
- **Release**: Automatically builds and publishes binaries when a version tag is pushed

### Workflow Status

- CI runs tests and builds on Linux, macOS, and Windows
- Releases are automatically created when pushing tags like `v1.0.0`

## Features

- ✅ Clean, readable formatting of Claude Code JSON output
- ✅ Tool use and tool result specialized formatting
- ✅ Color-coded output by message type
- ✅ Bold highlighting for keys
- ✅ Clean key: value format without JSON syntax
- ✅ Cross-platform support (Linux, macOS, Windows)
- ✅ Zero dependencies (pure Zig)
- ✅ Memory safe with no leaks

## License

MIT

