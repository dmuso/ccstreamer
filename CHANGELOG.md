# Changelog

All notable changes to ccstreamer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.1.12] - 2025-08-25

- Added header space for Mach-O binaries


## [v0.1.11] - 2025-08-24

- Added env var for Zig linker bug 


## [v0.1.10] - 2025-08-24

- Use Universal Binaries for Mac builds


## [v0.1.9] - 2025-08-24

- Tweaked Zig build flags for failing macos signing


## [v0.1.8] - 2025-08-24

- Signed binaries for MacOS 


## [v0.1.7] - 2025-08-24

- Adjusted build release steps to eliminate dupe builds


## [v0.1.6] - 2025-08-24

- Added write permissions for GitHub release


## [v0.1.5] - 2025-08-24

- Added GitHub token for release- 


## [v0.1.4] - 2025-08-24

### Fixed
- Adjusted GoReleaser config 


## [v0.1.3] - 2025-08-24

- GoReleaser for releases 


## [v0.1.2] - 2025-08-24

### Fixed
- GitHub upload artifact version fix


## [v0.1.1] - 2025-08-24

### Fixed
- Fixed build script, Windows build and linting 


## [0.1.0] - 24th August 2025

### Added
- Initial release of ccstreamer
- Basic JSON streaming support
- Message type detection and formatting
- Color management with ANSI escape sequences
- Content extraction from Claude Code JSON format
- Support for text, error, tool_use, tool_result, and status message types
- Cross-platform support (Linux, macOS, Windows)
- Comprehensive test suite
