# Gemini Persistent Context

This document provides a summary of the Malla project for the Gemini CLI to use as a persistent context for development and maintenance tasks.

## 1. Project Purpose

Malla is a framework for developing distributed services in Elixir. Its primary goal is to simplify distributed systems development by providing:

- A plugin-based architecture for composing functionality.
- Compile-time callback chaining for performance.
- Automatic service discovery and transparent remote procedure calls (RPC).
- Incremental adoption without technology lock-in.

The core design philosophy emphasizes simplicity, extensibility, and keeping the underlying system understandable ("no magic").

## 2. Stack and Dependencies

- **Language**: Elixir (~> 1.17)
- **Platform**: Erlang/OTP (26 or later)
- **Core Dependencies**:
    - `telemetry`: Used for instrumentation and observability.
- **Development Dependencies**:
    - `ex_doc`: For generating documentation.
    - `dialyxir`: For static analysis and type checking with Dialyzer.
- **Standard Libraries**: Leverages standard OTP applications like `:logger`, `:inets`, `:crypto`.

## 3. Architecture

The architecture is centered around OTP principles and a unique plugin system.

- **Core Component**: The `Malla.Service`. Developers use `use Malla.Service` to create a service, which is essentially a managed OTP process (likely a `GenServer`).
- **Plugin System**: The core of Malla's extensibility.
    - Services are themselves plugins.
    - Behavior is composed through a hierarchy of plugins (`Base` -> `Plugin` -> `Service`).
    - Callbacks are chained at **compile-time**, meaning there is zero runtime overhead for the plugin dispatch mechanism.
- **Distribution**:
    - Services can be marked as `global: true` to be discoverable across a cluster of Erlang nodes.
    - A local proxy module is dynamically created for remote services, allowing for transparent remote calls that look like local function calls.
- **OTP Application**: The project is structured as a standard OTP application, with `Malla.Application` serving as the entry point for the supervision tree.

## 4. Code Style and Conventions

- **Formatter**: The project uses `mix format` for consistent code formatting. Configuration is in `.formatter.exs`.
- **Custom Macros**: The framework defines several macros that are conventionally used without parentheses:
    - `defcb/1`, `defcb/2`: Defines a service "callback" (a remotely callable function).
    - `req/1`, `req/2`: Used within plugins to handle requests.
    - `callb/1`, `callb/2`: Used to call service callbacks.
- **Naming**: Follows standard Elixir conventions.

## 5. Key Files and Directories

- `mix.exs`: Project definition, dependencies, and configuration.
- `lib/malla.ex`: The main API module, likely containing the `use Malla.Service` macro.
- `lib/malla/application.ex`: The main OTP Application entry point and top-level supervisor.
- `lib/malla/service.ex`: The core logic for defining and creating services.
- `lib/malla/plugin.ex`: Defines the plugin behavior and compile-time callback chaining logic.
- `lib/malla/cluster.ex`: Handles node clustering and distributed communication.
- `lib/malla/registry.ex`: Manages the registration and discovery of local and global services.
- `guides/`: Contains the primary, in-depth documentation for the framework.
- `test/`: Contains the project's test suite.

## 6. Domain Model

- **Service**: A module that encapsulates a specific piece of functionality. It has a managed lifecycle and state. It's the primary unit of work for a user of the framework.
- **Plugin**: A module that provides composable behavior that can be attached to a service to extend its functionality (e.g., tracing, status handling, request parsing).
- **Callback (`defcb`)**: A function defined within a service that is part of its public API and can be called by other processes, both locally and remotely across the cluster.
- **Node**: A single instance of the Erlang VM running the application.
- **Cluster**: A network of interconnected nodes that work together, allowing services to be distributed.
- **Request**: Represents an invocation of a service callback. It flows through the plugin chain.
