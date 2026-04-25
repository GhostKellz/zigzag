# Contributing to ZigZag

Thank you for your interest in contributing to ZigZag.

## Getting Started

1. Fork the repository at [github.com/ghostkellz/zigzag](https://github.com/ghostkellz/zigzag)
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/zigzag.git
   cd zigzag
   ```
3. Build and test:
   ```bash
   zig build
   zig build test
   ```

## Development Requirements

- Zig 0.17.0-dev or later (we track Zig master)
- Linux for io_uring/epoll testing
- macOS for kqueue testing (optional)

## Code Style

- Follow Zig's standard library conventions
- Use `zig fmt` before committing
- Keep functions focused and small
- Prefer explicit over implicit

## Pull Request Process

1. Create a feature branch from `main`
2. Write tests for new functionality
3. Ensure all tests pass: `zig build test`
4. Update documentation if needed
5. Submit a pull request with a clear description

## Commit Messages

Use clear, descriptive commit messages:
- `fix: resolve timer race condition in epoll backend`
- `feat: add file watching support`
- `docs: update API reference for EventLoop`
- `refactor: simplify event coalescing logic`

## Testing

Run the full test suite:
```bash
zig build test
```

Run specific tests:
```bash
zig test src/root.zig
zig test src/backend/epoll.zig
```

## Release Verification

Before submitting changes, run the verification scripts:

```bash
# Full verification (build + tests + flag combinations)
./scripts/verify.sh

# Cross-compilation checks
./scripts/verify-cross.sh
```

Test build flag combinations:
```bash
zig build -Dio_uring=false    # Without io_uring
zig build -Depoll=false       # Without epoll
zig build -Dzsync=false       # Without zsync
zig build -Dterminal=false    # Without terminal features
```

## Reporting Issues

When reporting issues, include:
- Zig version (`zig version`)
- OS and kernel version
- Minimal reproduction case
- Expected vs actual behavior

## Code of Conduct

Be respectful and constructive. Focus on the code, not the person.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
