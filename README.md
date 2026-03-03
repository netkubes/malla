# Malla

Malla is a framework for developing distributed services in Elixir. It simplifies distributed service development through a plugin-based architecture with compile-time callback chaining, automatic service discovery across nodes, and minimal "magic" to keep systems understandable.

## Why Malla?

Developing distributed services can be challenging. Malla simplifies the process by handling much of the boilerplate while giving you the flexibility to implement custom behaviors and use any libraries without enforced constraints.

Malla is built on years of production experience running critical systems. This real-world battle testing has shaped its design to prioritize what matters most: simplicity, safe evolution, and practical flexibility.

### Not Just for Distributed Systems

While Malla excels at distributed computing, you don't need a cluster to benefit from it. On a single node, Malla gives you a plugin-based service architecture with compile-time callback chaining, runtime plugin management (add, remove, or reconfigure plugins without restarting), service lifecycle control, and built-in observability. If you need structured, evolvable services with runtime flexibility — even on a single BEAM instance — Malla has you covered. Distribution is there when you need it, but the service-management and runtime capabilities stand on their own.

### Key Principles

- **Simplicity and Readability First**: Production experience has taught us that keeping code simple and easy to understand is critical for long-term maintainability. Malla prioritizes straightforward, readable code over clever abstractions. The plugin architecture promotes focused code where each plugin handles a single concern. Compile-time callback chains mean no runtime complexity.
- **Safe Evolution Through Plugins**: Add new functionality or modify behavior without touching existing code. Plugins compose transparently, following the [Open/Closed Principle](https://en.wikipedia.org/wiki/Open%E2%80%93closed_principle). This reduces risk in production deployments—deactivate problematic plugins on the fly without requiring a full system restart.
- **No Technology Lock-In**: Malla has little friction with other libraries and integrates with your existing codebase incrementally. All built-in and future released plugins are optional. Use Malla for only part of your system—start with a single distributed service and expand gradually.

### Core Features

- **Plugin-Based Architecture**: Compose behavior through plugins with compile-time callback chaining (zero runtime overhead). Plugins can be **added and removed at runtime**, which is a game-changer for production operations.
- **Automatic Service Discovery**: Services automatically discover each other across the cluster.
- **Distributed RPC**: Call service functions on remote nodes transparently.
- **Service Lifecycle Management**: Control service state with admin statuses (`:active`, `:pause`, `:inactive`) and monitor their running status.
- **Dynamic Runtime Control**: Modify service behavior and plugin configurations in real-time. Deactivate problematic plugins on the fly without requiring a full system restart.
- **Extensive Documentation** and **Test Coverage**: Every major feature is documented and included in a test.

### Optional Included Utilities

- **Status and Error Management**: Built-in status tracking and error handling.
- **Process Registry**: Service-level process registration.
- **Tracing and Logging**: An instrumentation interface for observability.
- **Configuration Management**: Multi-layer configuration with deep merging.
- **Storage**: ETS-based storage per service.

## Installation

### Prerequisites

- Elixir 1.17 or later
- Erlang/OTP 26 or later

### Adding Malla to Your Project

Add `malla` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:malla, "~> 0.1.0"}
  ]
end
```

Then run `mix deps.get` to install the dependency.

## Quick Start

1.  **Define a service** with `use Malla.Service, global: true` to make it discoverable across the cluster.

    ```elixir
    defmodule MyService do
      use Malla.Service, 
        global: true
        
      # A callback that can be called remotely
      defcb fun1(a) do
        {:ok, %{you_said: a}}
      end
    end
    ```

2.  **Start the service** on one node.
    ```bash
    iex --sname node1 --cookie my_secret -S mix
    ```
    ```elixir
    iex(node1@hostname)> MyService.start_link()
    ```

3.  **Connect from another node** and call the service. Malla handles the remote call transparently.
    ```bash
    iex --sname node2 --cookie my_secret -S mix
    ```
    ```elixir
    iex(node2@hostname)> Node.connect(:"node1@hostname")
    true
    iex(node2@hostname)> MyService.fun1("hello from node2")
    {:ok, %{you_said: "hello from node2"}}
    ```

## Interactive Tutorials

The best way to learn Malla is through our interactive LiveBook tutorials:

- **[Getting Started Tutorial](livebook/getting_started.livemd)** - Learn the fundamentals through building a calculator service:
  - Create services and publish APIs
  - Extract functionality into reusable plugins
  - Compose plugins to modify behavior
  - Reconfigure services at runtime
  
- **[Distributed Services Tutorial](livebook/distributed_tutorial.livemd)** - Master distributed computing with Malla:
  - Set up a cluster with multiple LiveBook sessions
  - Create services that communicate across nodes
  - Experience automatic service discovery
  - Implement bidirectional service communication

Open these tutorials in [LiveBook](https://livebook.dev/) for an interactive, hands-on learning experience.

## Architecture Overview

### Plugin System

Malla's architecture centers on a sophisticated plugin system where behavior is composed through callback chains resolved at compile time:

```
Your Service Module (Top of chain - highest priority)
    ↓ Custom business logic
    ↓ Can override any plugin behavior
    ↓
Your Plugins (Middleware layer)
    ↓ Authentication, logging, caching
    ↓ Can modify, observe, or block calls
    ↓
Malla.Plugins.Base (Bottom of chain - default behavior)
    • Always present
    • Provides fallback implementations
```

Key characteristics:
- Service modules (using `Malla.Service`) are themselves plugins.
- Dependencies form a hierarchy: `Malla.Plugins.Base` (bottom) → plugins → your service module (top).
- Each callback invocation walks the chain from top to bottom until a plugin returns something different than `:cont`.
- This process has **zero runtime overhead**, as all chains are resolved at compile time.

### Distributed Services

Services marked as `global: true` automatically:
- Join the cluster-wide process group.
- Announce themselves to other nodes.
- Support automatic RPC routing with failover.
- Well-documented helper macros to make remote calls.

## Use Cases

Malla is ideal for:

- **Microservices Architecture**: Build distributed microservices that discover and communicate with each other.
- **Real-Time Systems**: Create services that require low-latency communication across nodes.
- **Scalable Applications**: Horizontally scale services with automatic load balancing.
- **Production Systems**: Deploy on Kubernetes and other modern platforms with runtime plugin management.

## Documentation

For a complete understanding of Malla's features, please see the full documentation in the **[guides](guides/01-introduction.md)** directory.

The guides provide a comprehensive overview of:
-   [Introduction](guides/01-introduction.md) - Why Malla and core concepts
-   [Services](guides/03-services.md) - Service fundamentals and lifecycle
-   [Plugins](guides/04-plugins.md) - Understanding the plugin system
-   [Lifecycle Management](guides/06-lifecycle.md) - Service state and transitions
-   [Configuration](guides/07-configuration.md) - Multi-layer configuration system
-   [Distribution](guides/08-distribution/01-cluster-setup.md) - Cluster setup and service discovery
-   [Observability](guides/09-observability/01-tracing.md) - Tracing and monitoring
-   [Plugin Development](guides/13-plugin-development.md) - Creating custom plugins
-   And more...

## AI-Assisted Development

Malla ships with instruction files that help AI coding assistants (Claude Code,
OpenAI Codex, Cursor, GitHub Copilot, etc.) generate correct Malla services and
plugins.

**If you use Malla as a dependency**, add this line to your project's AI
instruction file to teach your assistant about Malla patterns:

| Tool | File | Add this line |
|------|------|---------------|
| Claude Code | `CLAUDE.md` | `@deps/malla/priv/ai/AGENTS.md` |
| OpenAI Codex | `AGENTS.md` | `@deps/malla/priv/ai/AGENTS.md` |
| Cursor | `.cursor/rules/malla.md` | Copy the contents of `deps/malla/priv/ai/AGENTS.md` |
| Others | Your tool's instruction file | Reference or copy `deps/malla/priv/ai/AGENTS.md` |

**If you contribute to Malla itself**, the `AGENTS.md` and `CLAUDE.md` files at
the project root are automatically picked up by most AI coding tools.

## Contributing

Contributions are welcome! Please feel free to open an issue or submit a pull request.

## License

Malla is released under the Apache 2.0 License. See the LICENSE file for more details.
