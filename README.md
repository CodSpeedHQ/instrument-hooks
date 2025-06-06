<div align="center">
<h1>instrument-hooks</h1>

[![CI](https://github.com/CodSpeedHQ/instrument-hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/CodSpeedHQ/instrument-hooks/actions/workflows/ci.yml)
[![Discord](https://img.shields.io/badge/chat%20on-discord-7289da.svg)](https://discord.com/invite/MxpaCfKSqF)

Zig library to control instrumentations via IPC.

</div>

## Requirements

- **Zig**: 0.14
- [**Just**](https://github.com/casey/just) (optional): To easily run the build, formatter or tests

## How to add new integration?

Create a new release of this library:
```shell
just release
```

You can then include build and link to the files in `dist/`. Use the `dist/core.h` header to automatically generate bindings, or create them manually.

To test if it worked, call `is_instrumented` which should return `false` when running without Codspeed. To run with Codspeed, execute the following:
```
codspeed run -- <your_cmd>
```

To make sure your integration is fully working, you have to implement all these hooks:
- start_benchmark: Call this when the benchmark starts, to start measuring the performance.
- stop_benchmark: Stop measuring the performance after the benchmark stopped.
- executed_benchmark: Provide metadata about which benchmark was executed.
- set_integration: Provide metadata about the integration.

## Run tests

```
zig build test --summary all
```
or
```
just test
```
