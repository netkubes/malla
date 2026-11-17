# Malla

[![Hex.pm](https://img.shields.io/hexpm/v/malla.svg)](https://hex.pm/packages/malla)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/malla)
[![License](https://img.shields.io/hexpm/l/malla.svg)](https://github.com/netkubes/malla/blob/main/LICENSE.md)

Malla is a framework for developing distributed services in Elixir. A service is a module whose behavior is composed from plugins through callback chains that are resolved when the code is compiled. Services running on different Erlang nodes find each other and can call each other. The framework keeps the moving parts few and visible.

Malla is also useful on a single node: it gives you plugin-based services, a lifecycle with admin and running statuses, and plugins that can be added, removed or reconfigured while the service runs. Distribution is there when you need it.

## Installation

Add `malla` to the dependencies in `mix.exs`. Check [hex.pm/packages/malla](https://hex.pm/packages/malla) for the latest version:

```elixir
def deps do
  [
    {:malla, "~> 0.1"}
  ]
end
```

Then run `mix deps.get`. Malla requires Elixir 1.17 or later.

A first service, started and called from `iex -S mix`:

```elixir
defmodule MyService do
  use Malla.Service

  defcb greet(name), do: {:ok, "Hello, #{name}"}
end

iex> MyService.start_link()
iex> MyService.greet("world")
{:ok, "Hello, world"}
```

The [Quick Start](https://hexdocs.pm/malla/02-quick-start.html) continues from here, including a second node.

## Why Malla?

- **Plain code.** Plugins are modules with ordinary functions. Which implementation of a callback runs is decided at compile time and can be inspected with `MyService.service().plugin_chain`.
- **Change behavior by composition.** A plugin adds or modifies behavior without touching existing code. Plugins can be added to, or removed from, a running service.
- **Incremental adoption.** All plugins are optional. You can use Malla for one service and leave the rest of your application as it is.

Malla is built on production experience running distributed systems in Elixir.

## At a Glance

- **Plugin-based services.** Callbacks (`defcb`) are chained across the service and its plugins. The chain is resolved at compile time into direct function calls: low overhead, and no runtime lookup of who implements a callback. The chain is rebuilt when plugins are added or removed at runtime.
- **Runtime plugin management.** Add, remove and reconfigure plugins in a running service.
- **Service discovery.** Services declared with `global: true` are announced to the cluster through `:pg`. Calls reach a node running the service; if a node answers that the service is not available, the next node is tried.
- **Service lifecycle.** Admin status (`:active`, `:pause`, `:inactive`), running status, readiness and drain callbacks.
- **Optional building blocks.** Status and error normalization, a request protocol with trace propagation, an instrumentation API (spans, logs, metrics; the default implementation logs through `Logger` and emits `:telemetry` events), a small HTTP admin server with Kubernetes probes, per-service ETS storage and a process registry.

See the Livebook [Getting Started Tutorial](https://hexdocs.pm/malla/getting_started.html) and [Distributed Tutorial](https://hexdocs.pm/malla/distributed_tutorial.html).

## Documentation

Full documentation is available on **[HexDocs](https://hexdocs.pm/malla)**.

### Getting Started

| Guide | Description |
|-------|-------------|
| [Introduction](https://hexdocs.pm/malla/introduction.html) | What Malla is, core concepts and how the pieces fit |
| [Quick Start](https://hexdocs.pm/malla/02-quick-start.html) | Create your first service, then call it from a second node |
| [Glossary](https://hexdocs.pm/malla/00-glossary.html) | Terms used across the documentation |
| [Getting started tutorial](https://hexdocs.pm/malla/getting_started.html) | Interactive Livebook tutorial |
| [Distributed Tutorial](https://hexdocs.pm/malla/distributed_tutorial.html) | Multi-node Livebook tutorial |

### Core Concepts

| Guide | Description |
|-------|-------------|
| [Services](https://hexdocs.pm/malla/03-services.html) | Service fundamentals and the `defcb` macro |
| [Plugins](https://hexdocs.pm/malla/04-plugins.html) | The plugin system, dependencies and ordering |
| [Callbacks](https://hexdocs.pm/malla/05-callbacks.html) | How callback chains work |
| [Lifecycle](https://hexdocs.pm/malla/06-lifecycle.html) | Service statuses and transitions |
| [Configuration](https://hexdocs.pm/malla/07-configuration.html) | Configuration layers and every `config :malla` key |
| [Reconfiguration](https://hexdocs.pm/malla/07a-reconfiguration.html) | Changing configuration and plugins at runtime |
| [Storage and State](https://hexdocs.pm/malla/10-storage.html) | Per-service ETS table, process registry, node-wide store |

### Distribution

| Guide | Description |
|-------|-------------|
| [Cluster Setup](https://hexdocs.pm/malla/01-cluster-setup.html) | Connecting nodes, manually or through DNS |
| [Service Discovery](https://hexdocs.pm/malla/02-service-discovery.html) | How nodes find the services of other nodes |
| [Remote Calls](https://hexdocs.pm/malla/03-remote-calls.html) | `Malla.remote/4`, the `call` macro and virtual modules |

### Optional Plugins

| Guide | Description |
|-------|-------------|
| [Request Handling](https://hexdocs.pm/malla/04-request-handling.html) | Request protocol with trace propagation, status normalization and interception |
| [Status Handling](https://hexdocs.pm/malla/02-status-handling.html) | `Malla.Status` and `Malla.Plugins.Status` |
| [Tracing](https://hexdocs.pm/malla/01-tracing.html) | The instrumentation API and how to plug in a tracer |
| [HTTP Admin Server](https://hexdocs.pm/malla/11-http-admin.html) | Probes, drain endpoint and your own admin routes |

### Development and Operations

| Guide | Description |
|-------|-------------|
| [Plugin Development](https://hexdocs.pm/malla/13-plugin-development.html) | A complete worked plugin |
| [Testing](https://hexdocs.pm/malla/12-testing.html) | Testing services, plugins and multi-node scenarios |
| [Troubleshooting](https://hexdocs.pm/malla/14-troubleshooting.html) | Symptoms, causes and how to inspect a service |
| [Deployment](https://hexdocs.pm/malla/15-deployment.html) | Releases, clustering and Kubernetes |

## Part of the NetKubes Platform

Malla is the foundation of **NetKubes**, a platform for building distributed Elixir applications. Malla works as a standalone framework.

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
