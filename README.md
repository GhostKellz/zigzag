<p align="center">
  <img src="assets/icons/zigzag.png" alt="ZigZag Logo" width="200"/>
</p>

# zigzag

[![Zig](https://img.shields.io/badge/Zig-0.16.0--dev-orange?style=flat-square&logo=zig)](https://ziglang.org/)
[![Event Loop](https://img.shields.io/badge/Event%20Loop-High%20Performance-blue?style=flat-square)](https://github.com/yourusername/zigzag)
[![Cross Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey?style=flat-square)](https://github.com/yourusername/zigzag)
[![Backend](https://img.shields.io/badge/Backend-io__uring%20%7C%20kqueue%20%7C%20IOCP-green?style=flat-square)](https://github.com/yourusername/zigzag)
[![Zero Copy](https://img.shields.io/badge/Zero%20Copy-I%2FO-red?style=flat-square)](https://github.com/yourusername/zigzag)
[![Memory Safe](https://img.shields.io/badge/Memory-Safe-brightgreen?style=flat-square)](https://github.com/yourusername/zigzag)
[![Lock Free](https://img.shields.io/badge/Lock-Free-purple?style=flat-square)](https://github.com/yourusername/zigzag)
[![libxev Replacement](https://img.shields.io/badge/Replaces-libxev-yellow?style=flat-square)](https://github.com/yourusername/zigzag)

  🎯 zigzag - The Ultimate Zig Event Loop

  // zigzag - Lightning-fast event loop for Zig
  const zigzag = @import("zigzag");

  // The zigzag pattern of event processing
  const loop = try zigzag.init(.{
      .backend = .io_uring, // Linux
      .max_events = 1024,
  });

  while (loop.zigzag()) |events| { // 😍 Perfect API name!
      for (events) |event| {
          // Handle the zag part
          try processEvent(event);
      }
  }

  🚀 Ecosystem with zigzag:

  Ghostshell Terminal Stack
  ├── zigzag (event loop) 🆕 - The foundation
  ├── zsync (async runtime) - Built on zigzag
  ├── wzl (wayland) - Uses zigzag for events
  ├── phantom (TUI) - Lightning-fast with zigzag
  ├── gcode (unicode) - Static data, no I/O needed
  └── gvault (keychain) 🆕 - Secure storage

  🎯 Marketing Appeal:

  - "Zigzag your way to performance"
  - "The event loop that zigs and zags around bottlenecks"
  - "Lightning-fast zigzag pattern processing"

  ⚡ Perfect API Design:

  const loop = zigzag.init();
  while (loop.tick()) |batch| {
      // Process events in zigzag pattern
      for (batch.zigs()) |zig_event| { /* fast path */ }
      for (batch.zags()) |zag_event| { /* slow path */ }
  }

  zigzag is absolutely the perfect name! It's memorable, describes the functionality perfectly,
   fits your naming convention, and has that fun technical wordplay that developers love.

  Ready to build zigzag - The Ultimate Zig Event Loop? 🎯


