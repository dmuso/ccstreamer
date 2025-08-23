# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CC Streamer is a CLI application that accepts streamed JSON output from Claude Code and formats it for terminal display. The project is written in Zig and uses a modular architecture with separate library and executable modules.

## Build Commands

```bash
# Build the project
zig build

# Run the application
zig build run

# Run all tests
zig build test

# Run with arguments
zig build run -- [arguments]

# Build in release mode
zig build --release=fast
```

## Project Architecture

The codebase follows Zig's module system with two main entry points:
- `src/main.zig` - Executable entry point that will handle the CLI interface and JSON stream processing
- `src/root.zig` - Library module containing core functionality

The build system creates:
- A static library (`cc_streamer`) from `src/root.zig`
- An executable (`ccstreamer`) from `src/main.zig` that imports the library as `cc_streamer_lib`

## Development Environment

The project includes a Nix shell configuration (`shell.nix`) that provides:
- Zig compiler
- Node.js 20
- ripgrep
- Claude Code (via custom derivation)

To enter the development environment:
```bash
nix-shell
```

## Testing

Tests are integrated directly into source files using Zig's built-in testing framework. Run tests with:
```bash
zig build test
```

## Implementation Status

The project is in early development. The main application logic for parsing and formatting Claude Code's JSON stream output needs to be implemented in `src/main.zig`.