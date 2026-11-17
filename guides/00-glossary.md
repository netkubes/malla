# Glossary

This glossary defines key terms and concepts used throughout the Malla documentation.

## Core Concepts

### Service
A module that uses `Malla.Service`. Services are the core building blocks of a Malla application and can run locally or be distributed across a cluster. Services are themselves plugins at the top of the plugin chain.

### Service ID
The identifier of a service, which is the service's module name (for example `MyService`). Also referred to as `srv_id` in function parameters. Inside a process, the current service ID is kept in the process dictionary (see "Process Dictionary" below).

### Plugin
A module that uses `Malla.Plugin`. Plugins extend service functionality through composable, reusable behaviors. Services and the base plugin are plugins too.

### Callback
A function defined with `defcb` that participates in the plugin callback chain. Callbacks allow plugins to intercept, modify, or extend behavior as execution flows through the plugin hierarchy. A callback is identified by its name and arity.

### Callback Chain
The ordered sequence of modules that implement one callback, in the order they are called. It starts at the service (if the service defines the callback) and proceeds through the plugins that implement it, down to `Malla.Plugins.Base` if it implements it. Different callbacks can have different chains, because a module is in the chain of a callback only if it defines that callback.

### Plugin Chain
The ordered list of all the plugins of a service, from the service itself (top) to `Malla.Plugins.Base` (bottom). It is available as `MyService.service().plugin_chain`. The chain of each callback is the plugin chain filtered to the modules that implement it.

## Callback Chain Control

### `:cont`
Return value that continues callback chain execution with the same arguments to the next module in the chain that implements the callback.

### `{:cont, new_args}`
Return value that continues callback chain execution with modified arguments. A list replaces the whole argument list (so it must have as many elements as the callback has arguments); `{:cont, a, b}` is the same as `{:cont, [a, b]}`; any other single value becomes the only argument.

### Chain Stopping
When a callback returns any value other than `:cont` or `{:cont, ...}`, the chain stops immediately and that value is returned to the original caller. If the last module of the chain itself returns `:cont` or `{:cont, ...}`, that raw value is returned to the caller, because there is nowhere to continue.

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
- `:stopped` - Service has stopped its plugins
- `:failed` - A plugin could not start, or the supervisor of a plugin's children went down. The service process stays alive and tries again

## Distribution

### Global Service
A service marked with `global: true`: it joins the cluster-wide `:pg` process groups, which is how other nodes find it, including nodes that connect later. A service without it is not in the groups, but it still pushes its status to the nodes that are connected when it changes (see [Service Discovery](08-distribution/02-service-discovery.md)).

### Remote Call
A function or callback invocation on a service running on a different node in the cluster. Also called "RPC" (Remote Procedure Call) or "distributed call."

### RPC
Remote Procedure Call. See "Remote Call."

### Virtual Module
A module that `Malla.Node` generates at runtime on a node that has no module of that name, when it discovers a global service running on another node. It contains proxy functions only for the service's callbacks (`defcb`), so they can be called as if the module were local. Plain functions defined with `def` are not part of it.

### Service Discovery
The process by which nodes learn which services run where. Global services join the `:pg` group scope `Malla.Services2` (the groups are the service ID and `:all`), and `Malla.Node` on each node queries them.

### Failover
When a call is made through `Malla.Node.call/4` (and so by `Malla.remote/4`), the next node running the service is tried only if the node answers `{:error, :malla_service_not_available}`. An exception, a timeout or a lost connection is returned to the caller as `{:error, {:malla_rpc_error, ...}}` (by `Malla.remote/4`) and is not retried on another node unless `excp_retries` is set, which re-runs the call.

### Load Balancing
The nodes returned by `Malla.Node.get_nodes/1` have the local node first (if it runs the service) and the remote nodes in a random order, reshuffled each time services are re-checked (every 10 seconds and when a service changes status), not on each call.

## Lifecycle

### Plugin Lifecycle Callbacks
Standard Elixir callbacks (not `defcb`) that plugins implement to hook into service lifecycle events:
- `plugin_config/2` - Configuration phase (top-down), at start and on every reconfiguration
- `plugin_config_merge/3` - Merge of a configuration update (top-down), at start and on every reconfiguration
- `plugin_start/2` - Start phase (bottom-up)
- `plugin_updated/3` - Runtime reconfiguration (bottom-up)
- `plugin_stop/2` - Stop phase (top-down)
- `plugin_module/1` - Compile-time only: returns code that is spliced into the service module

### Service Lifecycle
The sequence a service goes through: initialization, configuration, start, running, (optional reconfiguration, pause), stop.

## Configuration

### Static Configuration
Configuration defined as extra keys of `use Malla.Service`. It is evaluated at compile time.

### Runtime Configuration
Configuration passed to `start_link/1` or provided in a supervisor's `child_spec`. Merged with static configuration when the service starts.

### Configuration Layer
One of the sources that are merged, in this order of precedence (lowest first):
1. Static configuration
2. OTP application configuration (`otp_app`)
3. Runtime configuration (`start_link/1`)

`Malla.Service.reconfigure/2` applies a further update on top of the running configuration.

### Deep Merge
The default merge: nested keyword lists are merged key by key. Values that are not keyword lists (maps, plain lists, scalars) are replaced by the update.

## Observability

### Span
A unit of work in tracing, created with `Malla.Tracer.span/2`. Spans can be nested.

### Trace
A collection of related spans.

### Distributed Tracing
Tracing across nodes. In Malla the trace context is passed only by `Malla.Request` (the `request-out` span hands its base to the `request-in` span on the called node); `Malla.remote/4` and virtual modules do not carry it. A tracer plugin decides what the context contains.

### Telemetry
The default tracer emits two `:telemetry` counters per span (start and stop). `Malla.metric/4` and the request protocol emit `:telemetry` events too.

## Request Handling

### Request Protocol
Structured system for inter-service communication that adds a pair of spans, response and error normalization and plugin interception on top of basic RPC.

### `req` Macro
Convenience macro for making requests using the request protocol. Imported with `use Malla.Request`.

### `malla_request/3` Callback
Callback that plugins can implement to intercept requests. It runs on the **called** service, before the target function is invoked; the calling service does not run it.

### Status
Standardized response format used by the request protocol, represented by the `%Malla.Status{}` struct.

## Storage

### Service Storage
ETS key-value table created for each service instance when its process starts. It is named after the service module, owned by the service process and lost when the process stops. Accessed via `Malla.Service.get/3`, `put/3`, `put_new/3` and `del/2`.

### Process Registry
`Malla.Registry`: a registry for naming and looking up processes, with unique names (`via/1`, `register/2`) and duplicate registrations (`store/2`). It is node-wide, not per service; keys include the service ID when you build them with `Malla.Service.child_via/3`.

### Global Config
Node-wide ETS-based store accessible via `Malla.Config`. It lives as long as the `:malla` application, so it survives service restarts, and it is not distributed.

## Plugin Concepts

### Plugin Dependency
Declaration that a plugin depends on another one, declared with the `plugin_deps:` option. The plugin is placed above its dependencies in the chain (called before them) and started after them.

### Optional Dependency
A plugin dependency marked with `{Plugin, optional: true}`. It fixes the order if the plugin is part of the service, but it does not pull the plugin in by itself, and a missing module is not an error.

### Plugin Group
Plugins that declare the same `group:`. Among the plugins listed in a service's `plugins:` option, each one of a group depends on the previous one of the same group in that list: they start in list order and their callbacks run in reverse list order.

### `Malla.Plugins.Base`
Plugin that is always at the bottom of every plugin chain. It provides default implementations of the standard callbacks.

## Technical Terms

### ETS
Erlang Term Storage. In-memory tables used by Malla for service storage and the node-wide store.

### EPMD
Erlang Port Mapper Daemon. Runs on port 4369 and helps Erlang nodes discover each other's distribution ports.

### Node
An instance of the Erlang runtime (BEAM). Malla services run on nodes, and nodes can be connected to form a cluster.

### Cookie
Secret string that nodes must share to connect to each other. It is the only authentication Erlang distribution has: a connected node can run any function on any other node.

### Process Dictionary
Per-process key-value storage. Malla uses it to store the current service ID, accessed via `Malla.get_service_id/0` and set with `Malla.put_service_id/1`. Calling a callback through the service module sets it for the duration of the call.

## Compile-Time Features

### Compile-Time Callback Chain
The mechanism by which Malla resolves plugin dependencies and generates dispatch code at compile time. Each hop of the chain is a function call plus a `case` on the returned value; chains of three or more modules walk a list with `apply/3`. There is no runtime lookup of who implements a callback. The dispatch module is recompiled when plugins are added or removed at runtime.

### `defcb`
Macro that defines a callback function participating in the plugin chain. In a service, the implementation is renamed (`my_callback_malla_service`) and a function with the original name is generated that calls the dispatch module.

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
