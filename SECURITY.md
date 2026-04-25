# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in ZigZag, please report it responsibly:

1. **Do not** open a public issue
2. Email the maintainers directly or use GitHub's private vulnerability reporting
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Security Considerations

ZigZag is a low-level event loop library. When using it:

- **File descriptors**: Ensure FDs are valid before passing to the event loop
- **Callbacks**: Callbacks execute in the same thread; avoid blocking operations
- **Memory**: Use Zig's allocator correctly; the library does not handle OOM gracefully in all paths
- **Signals**: Signal handlers have restrictions; keep them minimal

## Scope

This security policy covers the ZigZag library itself. It does not cover:
- Applications built with ZigZag
- Dependencies (zsync, etc.)
- The Zig compiler or standard library
