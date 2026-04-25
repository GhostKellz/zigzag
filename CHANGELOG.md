# Changelog

All notable changes to ZigZag are documented here.

## [0.1.6] - 2025-04-23

### Added
- Windows `EventLoop` socket operations: `addSocket()`, `recvSocket()`, `sendSocket()`, `removeSocket()`
- Native Windows file watching via `ReadDirectoryChangesW`
- Focused Windows smoke tests:
  - `test-windows-iocp`
  - `test-windows-filewatch`
  - `test-windows-stress`
- Windows stress coverage for:
  - wake flooding
  - recurring timer churn
  - mixed socket/timer/filewatch load
- IOCP socket tests: send/receive, async send, multiple pending ops, failed I/O, cleanup
- Windows verification script (scripts/verify-windows.sh)
- Native Windows PowerShell verification script (scripts/verify-windows.ps1)
- FileWatcher export from root module
- tests/test_utils.zig - Platform-independent test utilities
- scripts/verify.sh - Release verification script
- scripts/verify-cross.sh - Cross-compilation verification script

### Changed
- Migrated from zlog to `std.log` scoped loggers (native Zig logging)
- Updated for Zig 0.17.0-dev compatibility
- Updated zsync dependency to v0.8.1
- Version now sourced from build.zig.zon via `@import("build.zig.zon")`
- Windows documentation now presents IOCP as a supported, runtime-verified backend on Windows 11
- Windows verification now covers the runtime suite, focused socket/filewatch tests, and focused stress tests on the Win11 VM
- Event docs now clarify backend-neutral terminal semantics for `hangup` and `io_error`
- Restructured documentation into organized docs/ folder with subfolders:
  - docs/api/ - Complete API reference with accurate signatures
  - docs/guides/ - Quickstart and integration guides
  - docs/platform/ - Platform-specific documentation
  - docs/performance/ - Tuning and optimization guides
- Windows requirement updated to Windows 11

### Fixed
- Updated to use `std.Io.Threaded.closeFd()` (new 0.17.0-dev API)
- Updated to use `std.heap.DebugAllocator` (new 0.17.0-dev API)
- Fixed 16 instances of Linux-specific `std.os.linux.pipe()` in tests
- Added platform guards to tests for cross-platform compatibility
- Fixed io_uring backend deinit to properly cancel pending operations
- Fixed FileWatcher memory leak (owned event slices now freed)
- Fixed IOCP receive to use caller-provided buffer directly
- Fixed Windows file watching to support watches on files that do not exist yet, as long as the parent directory exists
- Fixed Windows file notification parsing to avoid alignment faults on variable-offset `FILE_NOTIFY_INFORMATION` entries
- Fixed cross-target compilation issues in `src/file_watching.zig` exposed by the new Windows-targeted verification path
- Fixed Windows verification script command handling so Zig subprocess execution works correctly under PowerShell on the Win11 VM

### Removed
- Removed zlog dependency (replaced with std.log)
- Removed zdoc dependency

## [0.1.5] - 2025-04-20

### Changed
- Removed abandoned zdoc and zlog dependencies
- Updated zsync to v0.8.0
- Zig 0.17.0-dev compatibility updates

## [0.1.4] - 2026-03-21

### Changed
- Updated for Zig 0.16.0-dev compatibility
- Updated zsync to v0.7.7

## [0.1.3] - 2026-02-13

### Added
- Event debugging module
- Thread safety primitives
- File watching support
- Network I/O module

## [0.1.2] - 2026-01-14

### Added
- Advanced timers with high-resolution support
- Async runtime integration with zsync
- Platform optimizations module

## [0.1.1] - 2025-11-03

### Added
- Performance profiling module
- Signal handling for terminals
- PTY management

## [0.1.0] - 2025-10-26

### Added
- Initial release
- Core event loop with multi-backend support
- epoll backend (Linux)
- io_uring backend (Linux 5.1+)
- kqueue backend (macOS/BSD)
- Timer management (one-shot and recurring)
- Event coalescing for terminal resize events
- Zero-copy I/O support
- Priority queue for events
