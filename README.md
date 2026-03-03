# Malla

[![Hex.pm](https://img.shields.io/hexpm/v/malla.svg)](https://hex.pm/packages/malla)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/malla)
[![License](https://img.shields.io/hexpm/l/malla.svg)](https://github.com/netkubes/malla/blob/main/LICENSE.md)

Malla is a framework for developing distributed services in Elixir. It simplifies distributed service development through a plugin-based architecture with compile-time callback chaining, automatic service discovery across nodes, and minimal "magic" to keep systems understandable.

**Not just for distributed systems** — even on a single node, Malla gives you plugin-based service management, runtime plugin control (add, remove, or reconfigure without restarting), lifecycle management, and built-in observability. Distribution is there when you need it.

## Why Malla?

- **Simplicity first** — straightforward, readable code over clever abstractions. Compile-time callback chains mean no runtime complexity.
- **Safe evolution** — add or modify behavior through plugins without touching existing code. Deactivate problematic plugins on the fly without restarting.
- **No lock-in** — integrates incrementally with your existing codebase. All plugins are optional. Start with a single service and expand gradually.

Built on years of production experience running critical systems.

## At a Glance

- **Plugin-based architecture** with compile-time callback chaining (zero runtime overhead)
- **Runtime plugin management** — add, remove, and reconfigure plugins on the fly
- **Automatic service discovery** across the cluster
- **Service lifecycle control** with admin and running statuses
- **No lock-in** — integrates incrementally with your existing codebase

## Documentation

Full documentation is available on **[HexDocs](https://hexdocs.pm/malla)**.

### Getting Started

| Guide | Description |
|-------|-------------|
| [Introduction](https://hexdocs.pm/malla/introduction.html) | Why Malla, core concepts, and key principles |
| [Quick Start](https://hexdocs.pm/malla/02-quick-start.html) | Create your first service in minutes |
| [Getting Started Tutorial](livebook/getting_started.livemd) | Interactive LiveBook tutorial |
| [Distributed Tutorial](livebook/distributed_tutorial.livemd) | Multi-node LiveBook tutorial |

### Core Concepts

| Guide | Description |
|-------|-------------|
| [Services](https://hexdocs.pm/malla/03-services.html) | Service fundamentals and the `defcb` macro |
| [Plugins](https://hexdocs.pm/malla/04-plugins.html) | The plugin system and callback chains |
| [Callbacks](https://hexdocs.pm/malla/05-callbacks.html) | How callback chaining works |
| [Lifecycle](https://hexdocs.pm/malla/06-lifecycle.html) | Service states and transitions |
| [Configuration](https://hexdocs.pm/malla/07-configuration.html) | Multi-layer configuration with deep merging |

### Distribution and Operations

| Guide | Description |
|-------|-------------|
| [Cluster Setup](https://hexdocs.pm/malla/01-cluster-setup.html) | Setting up a distributed cluster |
| [Service Discovery](https://hexdocs.pm/malla/02-service-discovery.html) | Automatic discovery across nodes |
| [Remote Calls](https://hexdocs.pm/malla/03-remote-calls.html) | Transparent RPC with failover |
| [Tracing](https://hexdocs.pm/malla/01-tracing.html) | Instrumentation and observability |
| [Plugin Development](https://hexdocs.pm/malla/13-plugin-development.html) | Creating custom plugins |

## Part of the NetKubes Platform

Malla is the foundation of **NetKubes**, a platform for building complex, distributed, production-ready Elixir applications. We will be releasing a series of plugins and tools covering deployment (Kubernetes and other platforms), runtime management, and common infrastructure needs. Malla works perfectly as a standalone framework — NetKubes plugins simply extend it when you need more.

## AI-Assisted Development

Malla ships with instruction files for AI coding assistants. If you use Malla as a dependency, add this to your project's AI instruction file:

| Tool | File | Add this line |
|------|------|---------------|
| Claude Code | `CLAUDE.md` | `@deps/malla/priv/ai/AGENTS.md` |
| OpenAI Codex | `AGENTS.md` | `@deps/malla/priv/ai/AGENTS.md` |
| Cursor | `.cursor/rules/malla.md` | Copy contents of `deps/malla/priv/ai/AGENTS.md` |

## Contributing

Contributions are welcome! Please feel free to open an issue or submit a pull request.

## License

Malla is released under the Apache 2.0 License. See the [LICENSE](LICENSE.md) file for details.
