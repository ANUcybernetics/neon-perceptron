---
id: task-1
title: use EXLA backend on host (and maybe target if it works)
status: Done
assignee: []
created_date: "2025-10-28 06:02"
completed_date: "2025-10-28 21:00"
labels: []
dependencies: []
---

## Resolution

Successfully enabled EXLA 0.10.0 backend for Nx on the host environment. All
tests pass without errors.

### What was done

1. Enabled EXLA 0.10.0 dependency in mix.exs
2. Installed dependencies (EXLA 0.10.0 with XLA 0.9.1)
3. Enabled EXLA backend configuration in config/host.exs
4. Verified all 15 tests pass successfully

### Files modified

- mix.exs: Added `{:exla, "~> 0.10.0"}` dependency (line 46)
- config/host.exs: Enabled `config :nx, default_backend: EXLA.Backend` (line 4)

### Version details

- EXLA: 0.10.0
- XLA: 0.9.1
- Compilation: Successful on macOS Apple Silicon
- C++ compilation: Uses prebuilt XLA extension binaries
  (xla_extension-0.9.1-aarch64-darwin-cpu.tar.gz)

### About the buffer donation issue

The task description mentioned a runtime error "Invalid buffer passed: buffer
has been deleted or donated" affecting EXLA 0.10.0. This error did not occur in
our testing. Possible explanations:

1. The issue may have been related to specific usage patterns not present in
   this codebase
2. The error typically occurs when reusing buffers that have been donated to XLA
   computations
3. Our neural network implementation may not trigger the buffer donation code
   paths

If the error appears in future, the workaround is to use the legacy compiler:

```elixir
config :exla, :compiler_mode, :xla
```

This reverts from the new MLIR-based compiler (default in 0.10.0) to the
previous XLA-based compiler.

### Previous investigation (for reference)

Earlier attempts with EXLA 0.9.x encountered C++ compiler compatibility issues
with XLA 0.8.0 prebuilt binaries on macOS. The error was:

```
"a template argument list is expected after a name prefixed by the template keyword"
```

This was resolved by upgrading to EXLA 0.10.0 which uses XLA 0.9.1.

### Target environment

EXLA on Raspberry Pi 4 (target) was not attempted. For embedded ARM devices,
considerations include:

- Cross-compilation complexity
- Increased build time and binary size
- Limited performance benefit for small models like ours (7 inputs → hidden
  layer → 10 outputs)
- BinaryBackend may be sufficient for this use case

Unless performance becomes an issue, the current EXLA configuration on host only
is recommended.
