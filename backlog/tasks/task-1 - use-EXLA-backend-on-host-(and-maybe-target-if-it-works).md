---
id: task-1
title: use EXLA backend on host (and maybe target if it works)
status: Blocked
assignee: []
created_date: "2025-10-28 06:02"
labels: []
dependencies: []
---

## Investigation summary

Attempted to enable EXLA backend for Nx on the host environment, but encountered
C++ compiler compatibility issues with the prebuilt XLA binaries on macOS (Apple
Silicon).

### Issues encountered

**EXLA 0.9.x (with XLA 0.8.0):**

- Compilation fails with C++ template errors in XLA headers
- Error: "a template argument list is expected after a name prefixed by the
  template keyword"
- The prebuilt XLA extension headers
  (xla_extension-0.8.0-aarch64-darwin-cpu.tar.gz) are incompatible with the
  system C++ compiler

**EXLA 0.10.0 (with XLA 0.9.1):**

- Compilation succeeds
- Runtime error: "Invalid buffer passed: buffer has been deleted or donated"
- This is a known issue with EXLA 0.10.0 that affects basic tensor operations

### Current state

- EXLA dependency remains commented out in mix.exs (line 46)
- Config for EXLA backend is commented out in config/host.exs (lines 4-6)
- Project uses Nx 0.10.0 with default BinaryBackend
- All tests pass with BinaryBackend

### Performance considerations

The neural network in this project is quite small (7 inputs → hidden layer → 10
outputs), so:

- BinaryBackend performance is likely acceptable for this use case
- EXLA compilation overhead might outweigh any performance gains
- Training with 10,000 epochs takes time regardless of backend

### Recommendations

1. **Wait for EXLA updates**: Monitor EXLA releases for fixes to either the C++
   compilation issues (0.9.x) or runtime buffer errors (0.10.x)
2. **Build from source**: Could try building XLA from source instead of using
   prebuilt binaries, though this adds significant complexity
3. **Alternative approach**: Use Nx's JIT compilation with `Nx.Defn.jit` for
   specific hot paths instead of global backend
4. **Accept BinaryBackend**: Given the small model size, the pure Elixir backend
   may be sufficient

### Files modified (reverted)

- mix.exs: EXLA dependency commented out with note
- config/host.exs: EXLA backend configuration commented out with reference to
  this task

### Target environment

EXLA on Raspberry Pi 4 (target) was not attempted due to host compilation
failures. Even if host issues are resolved, EXLA on ARM embedded devices
presents additional challenges:

- Increased build time and binary size
- Limited benefit for small models
- May require cross-compilation setup
