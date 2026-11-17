# Services

A service in Malla is a module that uses `Malla.Service` and implements zero or more callbacks. Services are the core building block of a Malla application and can run locally or be distributed across a cluster.

By using `use Malla.Service`, a module gains:
- **Discovery**: it is announced to the other nodes of the cluster if `global: true`.
- **Plugin architecture**: extensibility through a compile-time callback chain.
- **Status management**: administrative control (`:active`, `:pause`, `:inactive`) and a running status.
- **Supervision of plugin children**: each plugin can start children under its own supervisor.
- **ETS storage**: a table created when the service process starts and lost when it stops.
- **Instrumentation hooks**: with `Malla.Plugins.Tracer` (see [Tracing](09-observability/01-tracing.md)).

## Defining a Service

To define a service, you `use Malla.Service` in your module and implement your business logic.

```elixir
defmodule MyService do
  use Malla.Service,
    global: true,
    plugins: [SomePlugin],
    vsn: "1.0.0"

  # A regular function - can be called remotely with Malla.remote/4,
  # but it is not in the callback chain.
  def my_function(arg), do: arg

  # A callback - participates in the plugin chain.
  defcb my_callback(arg) do
    # do work...
    :cont  # or return a value to stop the chain
  end
end
```

### Functions vs. Callbacks

Services expose two types of operations:
1.  **Regular functions** (defined with `def`): standard Elixir functions. They can be called remotely with `Malla.remote/4`, but they do not participate in the plugin callback chain and they are not part of the virtual module that other nodes generate for the service.
2.  **Callbacks** (defined with `defcb`): functions that are part of the plugin chain, allowing plugins to intercept, modify, or extend their behavior. Calling `MyService.my_callback(arg)` sets the service ID in the process dictionary for the duration of the call.

See the [Callbacks guide](05-callbacks.md) for a detailed explanation.

## Service Options

You can configure a service via options in the `use Malla.Service` macro:

- `:global` - (boolean) If `true`, the service joins the cluster-wide `:pg` process groups, so the other nodes can discover it, including nodes that connect later. Defaults to `false`. A non-global service is not published in the groups, but it still announces its status changes to the nodes connected at that moment, so `false` is not an access control (see [Service Discovery](08-distribution/02-service-discovery.md)).
- `:plugins` - (list of modules) The plugins of the service. Can also be provided at runtime via `start_link/1`, replacing this list. See [Plugins](04-plugins.md).
- `:class` - (atom) Free metadata; Malla does not use it.
- `:vsn` - (string) A version string, default `""`. Malla only carries it as metadata: it appears in the service info (`Malla.Service.get_service_info/2`, `Malla.Node.get_instances/1`), and it is not used to check compatibility between nodes.
- `:otp_app` - (atom) Load additional configuration from the specified OTP application's environment. See [Configuration](07-configuration.md).
- `:paused` - (boolean) If `true`, the service starts with admin status `:pause`: it goes to the `:paused` running status without starting the children of its plugins, and it is not listed as available to other nodes until you call `set_admin_status(:active)`. See the [Lifecycle guide](06-lifecycle.md).
- `:silent` - (boolean) If `true`, the lifecycle messages of the service (start, status changes, reconfiguration, at levels below `warning`) are not logged.
- `:priority` - (integer, default `0`) Only sets the order in which `Malla.Service.drain_all_local/0` drains the services of a node, lowest first (see [Service Lifecycle](06-lifecycle.md)).
- Any other key-value pairs are added to the service's initial configuration. See the [Configuration guide](07-configuration.md).

### Options that cannot be set at runtime

`:class`, `:vsn`, `:global`, `:paused`, `:silent`, `:priority` and `:otp_app` belong to the `use` macro. A runtime configuration that carries one of them (a start option, the `config :my_app, MyService, ...` environment, or `reconfigure/2`) is refused with `{:error, {:key_not_allowed_in_service_start, key}}`:

```elixir
iex> MyService.reconfigure(vsn: "2.0.0")
{:error, {:key_not_allowed_in_service_start, :vsn}}
```

With `start_link/1` the error comes out as an exit of the linked caller (`start_link/1` is a `GenServer.start_link/3`); under a supervisor, or with ExUnit's `start_supervised/1`, you get `{:error, {{:key_not_allowed_in_service_start, :vsn}, child_spec}}`.

## Service Lifecycle

Services have two independent status dimensions:

- **Admin status**: `:active`, `:pause`, `:inactive`. This is controlled by the operator (`set_admin_status/2`).
- **Running status**: `:starting`, `:running`, `:pausing`, `:paused`, `:stopping`, `:stopped`, `:failed`. This is the operational state managed by the service process.

For a detailed explanation, see the [Lifecycle guide](06-lifecycle.md).

## Starting a Service

You can start a service directly or as part of a supervisor tree.

```elixir
# Start the service directly
{:ok, pid} = MyService.start_link()

# Start with runtime configuration
{:ok, pid} = MyService.start_link(key: :value)

# Start with runtime plugins (replaces the compile-time plugin list)
{:ok, pid} = MyService.start_link(plugins: [SomePlugin, AnotherPlugin])

# Start under a supervisor
children = [
  {MyService, key: :value}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

`start_link/1` returns as soon as the process has initialized and merged its configuration. The plugins are started right after, by the service process itself. To wait for the service to be running, call `Malla.Service.get_service_info/2` (it is answered after the first start attempt) or poll `MyService.get_status/0`.

The child spec generated by `use Malla.Service` has `restart: :transient` and `shutdown: :infinity`, so a supervisor does not restart a service that you stopped with `MyService.stop/0`, and it waits for the plugins to stop.

### The functions `use Malla.Service` adds

The module gets the functions of the `Malla.Service.Interface` behaviour: `start_link/1`, `stop/0`, `child_spec/1`, `set_admin_status/2`, `reconfigure/1`, `get_config/0` and `get_status/0`, plus `service/0`, which returns the `t:Malla.Service.t/0` struct (plugin chain, callbacks, static configuration). The module-independent versions are in `Malla.Service`: `get_config/1`, `get_status/1`, `is_live?/1`, `is_ready?/1`, `drain/1`.

### Runtime Plugin Specification

You can pass `plugins:` to `start_link/1` to replace the compile-time plugin list. This is useful, for example, for escript/CLI deployments where the plugin selection comes from configuration files.

```elixir
# Define a service with no plugins at compile time
defmodule MyService do
  use Malla.Service,
    global: true
end

# At runtime, choose plugins based on configuration
plugins = load_plugins_from_config()
{:ok, pid} = MyService.start_link(plugins: plugins, my_plugin: [timeout: 5000])
```

The plugin chain is rebuilt at startup: dependencies are resolved, callbacks are regenerated and the dispatch module is recompiled. Because the dispatch module is a module of the running VM, the rebuilt chain stays loaded after the service stops: if you start the same service again without `plugins:`, it starts with the chain that was last built, not with the compile-time one. The same happens with `add_plugin/3`, `del_plugin/2` and `reconfigure/2` with `plugins:`, and those rebuilds also keep the configuration the service had at that moment as its new initial configuration. A new VM starts again with the compile-time chain. See [Reconfiguration](07a-reconfiguration.md).

## Inspecting a Running Service

```elixir
{:ok, info} = Malla.Service.get_service_info(MyService)
info.running_status   # :running
info.admin_status     # :active
info.vsn              # "1.0.0"
info.last_error       # nil, or the reason of the last failed start
info.plugins          # %{plugin_module => {supervisor_pid | :none, start_options} | nil}
```

`get_service_info/2` is a call to the service process (default timeout 5000 ms). It returns `{:ok, info}`; `info` also has `:id`, `:pid`, `:node`, `:hash`, `:last_status_reason`, `:last_status_time`, `:last_error_time` and `:callbacks` (a list of `{name, arity}`). `get_status/1` and `get_config/1` read cached values and return `:unknown` if the service process is not running.

## Service Storage

Each service instance has its own ETS table, named after the service module. It is created when the service process starts and it disappears when the process ends.

See [Storage and State](10-storage.md) for details.

## Next Steps

- [Plugins](04-plugins.md) - Understand the plugin system.
- [Callbacks](05-callbacks.md) - Learn more about callback chains.
- [Lifecycle](06-lifecycle.md) - Get a deep dive into the service lifecycle.
- [Configuration](07-configuration.md) - Learn how to configure your services.
- [Reconfiguration](07a-reconfiguration.md) - Learn how to update service configuration at runtime.
