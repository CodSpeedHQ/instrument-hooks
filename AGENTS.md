# instrument-hooks

Zig library that compiles to a single-file C library (`dist/core.c`) for controlling CodSpeed instrumentations via IPC. Consumed as FFI by integrations in multiple languages (Python, Rust, C/C++, etc.).

## Build & Test

```bash
zig build                    # Build (outputs zig-out/lib/core.c)
zig build test --summary all # Run tests
just release                 # Build + generate dist/core.c
just cmake-run-example       # Build and run the C example via CMake
just bazel-run-example       # Build and run the C example via Bazel
just test-valgrind           # Compile example with gcc/clang and run under valgrind
just fmt                     # Format Zig source
```

Requires **Zig 0.14+**. Optional: [Just](https://github.com/casey/just) for convenience commands.

## Architecture

### Source layout

- `src/c.zig` — C FFI export layer. All public API functions are defined here with `pub export fn`.
- `src/instrument_hooks.zig` — Main `InstrumentHooks` struct combining all subsystems.
- `src/instruments/root.zig` — Instrumentation backend union (valgrind, perf, analysis, none). Fallback chain: valgrind > analysis > perf > none.
- `src/instruments/{valgrind,perf,analysis}.zig` — Individual backends.
- `src/runner_fifo.zig` — IPC protocol with the CodSpeed runner via Unix named pipes.
- `src/fifo.zig` — Low-level Unix pipe reader/writer with bincode serialization.
- `src/shared.zig` — Protocol types (`Command` union, `MarkerType`, version).
- `src/bincode.zig` — Bincode binary serialization (port of qbradley/bincode-zig).
- `src/environment/root.zig` — Key-value integration/toolchain metadata and linked library collection, serialized to JSON.
- `src/environment/linked_libraries/root.zig` — Collects metadata about dynamically linked libraries (path, soname, build ID, verdef).
- `src/environment/linked_libraries/elf_view.zig` — Read-only ELF navigation helper for parsing in-memory program headers (PT_DYNAMIC, PT_NOTE, DT_VERDEF). Portable across all Linux architectures.
- `src/environment/linked_libraries/testdata/test_lib.c` — Minimal C source compiled into a test fixture `.so` by `build.zig`. Linked into the test binary so it appears in `dl_iterate_phdr` for ElfView tests.
- `src/features.zig` — Runtime feature flags (bit set).
- `src/logger.zig` — Simple leveled logging via C `printf`.
- `src/utils.zig` — Low-level utilities (clock_gettime, sleep).
- `src/root.zig` — Test runner entry point (imports all modules for testing).

### Headers & distribution

- `includes/core.h` — Manually maintained C API header. Must be updated when adding/removing exported functions.
- `includes/compat.h` — Cross-platform compatibility macros.
- `includes/valgrind.h`, `includes/callgrind.h` — Valgrind client request headers.
- `dist/core.c` — Generated single-file C library. Linux gets the full Zig-transpiled implementation, Windows/macOS get stubs from `scripts/stub.c`.
- `scripts/release.py` — Combines generated C, stubs, and valgrind wrapper into `dist/core.c`.
- `scripts/stub.c` — Stub implementations for Windows/macOS. Must be updated when adding exported functions.

### IPC protocol

Communication with the CodSpeed runner happens over two named pipes:
- `/tmp/runner.ctl.fifo` — Commands (hooks -> runner)
- `/tmp/runner.ack.fifo` — Acknowledgments (runner -> hooks)

Messages use bincode serialization with `[u32 length][payload]` framing. Protocol version: 2.

## Conventions

### Adding a new exported function

1. Implement the logic in the appropriate module.
2. Add the `pub export fn` wrapper in `src/c.zig`. Return `u8` status codes (0 = success, non-zero = error).
3. Add the declaration in `includes/core.h`.
4. Add a stub in `scripts/stub.c`.
5. Run `just release` to regenerate `dist/core.c`.

### Code style

- Zig code is formatted with `zig fmt`.
- C/C++ code follows Google style (`.clang-format`), pointer-left alignment.
- Pre-commit hooks enforce formatting and build checks.
- Error handling at FFI boundary: return `u8` (0 = ok, 1 = error). Never panic in release builds (`std.debug.no_panic`).
- Memory: `std.heap.c_allocator` in production, `std.testing.allocator` in tests.
- Hot paths (FIFO read/write) use pre-allocated buffers to avoid allocations.

### Testing

- Tests live alongside the code in each `.zig` file.
- `src/root.zig` imports all modules to run all tests.
- `build.zig` compiles a test fixture shared library (`libtest_fixture.so`) from `src/environment/linked_libraries/testdata/test_lib.c` and links it into the test binary. ElfView tests use `dl_iterate_phdr` to find it at runtime — no file parsing, same code path as production.
- CI tests across multiple platforms (Linux x86/ARM, macOS, Windows), compiler versions (GCC 9-15, Clang 13-19), and cross-compilation targets.

### Commit messages

Follow conventional commits. Reference Linear issues when applicable (inferred from branch name).
