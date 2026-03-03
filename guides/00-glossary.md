# Glossary

This glossary defines key terms and concepts used throughout the Malla documentation.

## Core Concepts

### Service
A module that uses `Malla.Service`. Services are the core building blocks of a Malla application and can run locally or be distributed across a cluster. Services are themselves plugins at the top of the plugin chain.

### Service ID
The identifier for a service instance, typically the service's module name (e.g., `MyService`). Also referred to as `srv_id` in function parameters. Used to reference a specific service instance in the cluster.

### Plugin
A module that uses `Malla.Plugin`. Plugins extend service functionality through composable, reusable behaviors. Everything in Malla is a plugin, including services and the base plugin.

### Callback
A function defined with `defcb` that participates in the plugin callback chain. Callbacks allow plugins to intercept, modify, or extend behavior as execution flows through the plugin hierarchy.

### Callback Chain
The ordered sequence of plugins through which a callback execution flows. Starts at the service (top) and proceeds down through plugins to `Malla.Plugins.Base` (bottom). Also called the "plugin chain."

### Plugin Chain
Another term for callback chain. Refers to the hierarchy of plugins through which execution flows.

## Callback Chain Control

### `:cont`
Return value that continues callback chain execution with the same arguments to the next plugin in the chain.

### `{:cont, new_args}`
Return value that continues callback chain execution but with modified arguments passed to the next plugin.

### Chain Stopping
When a callback returns any value other than `:cont` or `{:cont, ...}`, the chain stops immediately and that value is returned to the original caller.

## Service Status

### Admin Status
User-controlled status indicating the desired state of a service. Can be:
- `:active` - Service should be running
- `:pause` - Service should be paused
- `:inactive` - Service should not be running

Also called "administrative status."

### Running Status
System-managed status indicating the actual operational state. Can be:
- `:starting` - Service is starting up
- `:running` - Service is fully operational
- `:pausing` - Service is transitioning to paused
- `:paused` - Service is paused
- `:stopping` - Service is shutting down
- `:stopped` - Service has stopped
- `:failed` - Service has failed

## Distribution

### Global Service
A service marked with `global: true` that registers itself cluster-wide and can be called from any node. Non-global services only run locally.

### Remote Call
A function or callback invocation on a service running on a different node in the cluster. Also called "RPC" (Remote Procedure Call) or "distributed call."

### RPC
Remote Procedure Call. See "Remote Call."

### Virtual Module
A dynamically created local proxy module for a remote service. Allows calling remote services as if they were local modules, without explicit RPC code.

### Service Discovery
The automatic process by which services find each other across the cluster. Malla uses Erlang's `:pg` process group for service discovery.

### Failover
Automatic retry mechanism that attempts to call a service on alternative nodes if the first attempt fails.

## Lifecycle

### Plugin Lifecycle Callbacks
Standard Elixir callbacks that plugins implement to hook into service lifecycle events:
- `plugin_config/2` - Configuration phase (top-down)
- `plugin_start/2` - Start phase (bottom-up)
- `plugin_updated/3` - Runtime reconfiguration
- `plugin_stop/2` - Stop phase (top-down)

### Service Lifecycle
The complete sequence a service goes through from startup to shutdown: Initialization → Configuration → Start → Running → (optional Reconfigure/Pause) → Stop → Cleanup.

## Configuration

### Static Configuration
Configuration defined in the `use Malla.Service` macro or with the `config` macro. Set at compile time.

### Runtime Configuration
Configuration passed to `start_link/1` or provided in a supervisor's `child_spec`. Merged with static configuration at runtime.

### Configuration Layer
One of four configuration sources that are deep-merged in order of precedence:
1. Static configuration (lowest precedence)
2. OTP application configuration
3. Runtime configuration
4. Runtime reconfiguration (highest precedence)

### Deep Merge
Configuration merging strategy where nested maps and keyword lists are recursively merged rather than replaced.

## Observability

### Span
A unit of work in distributed tracing, representing a specific operation. Spans can be nested to create a trace hierarchy.

### Trace
A collection of related spans showing the path of execution across multiple services and nodes.

### Distributed Tracing
Tracing that automatically propagates context across service boundaries and nodes, creating a unified view of request flow.

### Telemetry
Built-in metrics and event emission system for monitoring Malla services.

## Request Handling

### Request Protocol
Structured system for inter-service communication that adds tracing, error normalization, retries, and plugin interception on top of basic RPC.

### `req` Macro
Convenience macro for making requests using the request protocol. Imported from `Malla.Request`.

### `malla_request/3` Callback
Callback that plugins can implement to intercept requests before they're sent to remote services.

### Status
Standardized response format used by the request protocol, represented by `%Malla.Status{}` struct.

## Storage

### Service Storage
ETS-based key-value storage automatically created for each service instance. Created on start, destroyed on stop. Accessed via `Malla.Service.get/3`, `put/3`, etc.

### Service Registry
Process registry for naming and looking up processes within a service. Supports both unique names and duplicate (multi-registration).

### Global Config
Node-wide ETS-based configuration store accessible via `Malla.Config`. Survives service restarts but is not distributed.

## Plugin Concepts

### Plugin Dependency
Explicit declaration that one plugin depends on another, establishing ordering in the callback chain. Declared with `plugin_deps:` option.

### Optional Dependency
A plugin dependency marked with `{Plugin, optional: true}` that won't cause an error if the plugin is not available.

### Plugin Group
A set of plugins assigned to the same group name. Plugins in the same group are automatically ordered sequentially based on their declaration order.

### `Malla.Plugins.Base`
Special plugin that is always at the bottom of every plugin chain. Provides default implementations for all standard callbacks.

## Technical Terms

### ETS
Erlang Term Storage. In-memory database used by Malla for service storage, configuration, and registries.

### EPMD
Erlang Port Mapper Daemon. Runs on port 4369 and helps Erlang nodes discover each other's distribution ports.

### Node
An instance of the Erlang runtime (BEAM). Malla services run on nodes, and nodes can be connected to form a cluster.

### Cookie
Secret string that nodes must share to connect to each other. Acts as a basic authentication mechanism for Erlang distribution.

### Process Dictionary
Per-process key-value storage. Malla uses it to store the current service ID during callback execution, accessed via `Malla.get_service_id/0`.

## Compile-Time Features

### Compile-Time Callback Chain
The mechanism by which Malla resolves plugin dependencies and generates optimized callback dispatch code at compile time, ensuring zero runtime overhead.

### Zero Runtime Overhead
Design principle where plugin chain resolution and dispatch happens entirely at compile time, adding no performance cost during execution.

### `defcb`
Macro that defines a callback function participating in the plugin chain. At compile time, it's renamed and wrapped in dispatch logic.

## Common Abbreviations

- **srv_id**: Service ID
- **RPC**: Remote Procedure Call
- **ETS**: Erlang Term Storage  
- **EPMD**: Erlang Port Mapper Daemon
- **OTP**: Open Telecom Platform (Erlang/Elixir's application framework)
- **DNS**: Domain Name System
- **SRV**: Service record (DNS record type)

## See Also

- [Introduction](01-introduction.md) - Framework overview
- [Services](03-services.md) - Service fundamentals
- [Plugins](04-plugins.md) - Plugin system
- [Callbacks](05-callbacks.md) - Callback chains
- [Lifecycle](06-lifecycle.md) - Service lifecycle
