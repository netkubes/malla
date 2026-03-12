# Services

A service in Malla is a module that uses `Malla.Service` and implements one or more callbacks. Services are the core building block of a Malla application and can run locally or be distributed across a cluster.

By using `use Malla.Service`, a module gains:
- **Automatic Discovery**: Becomes visible to all nodes in the cluster (if `global: true`).
- **Plugin Architecture**: Extensibility through a compile-time callback chain.
- **Status Management**: Administrative control (`:active`, `:pause`, `:inactive`).
- **Supervision**: A standard supervisor for service-specific children.
- **ETS Storage**: A runtime data store that is created on start and destroyed on stop.
- **Observability**: Built-in tracing and introspection hooks.

## Defining a Service

To define a service, you `use Malla.Service` in your module and implement your business logic.

```elixir
defmodule MyService do
  use Malla.Service,
    global: true,
    plugins: [SomePlugin],
    vsn: "1.0.0"

  # A regular function - available for remote calls but not in the callback chain.
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
1.  **Regular Functions** (defined with `def`): Standard Elixir functions that can be called remotely but do not participate in the plugin callback chain.
2.  **Callbacks** (defined with `defcb`): Functions that are part of the plugin chain, allowing plugins to intercept, modify, or extend their behavior.

See the [Callbacks guide](05-callbacks.md) for a detailed explanation.

## Service Options

You can configure a service via options in the `use Malla.Service` macro:

- `:global` - (boolean) If `true`, the service is registered cluster-wide and can be called from any node. Defaults to `false`.
- `:plugins` - (list of modules) A list of plugins to include in the service's callback chain. Can also be provided at runtime via `start_link/1`. See [Plugins](04-plugins.md).
- `:vsn` - (string) The service version, used for compatibility checking.
- `:otp_app` - (atom) Load additional configuration from the specified OTP application's environment.
- Any other key-value pairs are added to the service's initial configuration. See the [Configuration guide](07-configuration.md).

## Service Lifecycle

Services have two independent status dimensions:

- **Admin Status**: `:active`, `:pause`, `:inactive`. This is controlled by the administrator/operator.
- **Running Status**: `:starting`, `:running`, `:paused`, `:stopped`, `:failed`. This is the operational state managed by the system.

For a detailed explanation of the service lifecycle, see the [Lifecycle guide](06-lifecycle.md).

## Starting a Service

You can start a service directly or as part of a supervisor tree.

```elixir
# Start the service directly
{:ok, pid} = MyService.start_link()

# Start with runtime configuration
{:ok, pid} = MyService.start_link(key: :value)

# Start with runtime plugins (replaces compile-time plugin list)
{:ok, pid} = MyService.start_link(plugins: [SomePlugin, AnotherPlugin])

# Start under a supervisor
children = [
  {MyService, key: :value}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Runtime Plugin Specification

You can pass `plugins:` to `start_link/1` to override the compile-time plugin list. This is useful for escript/CLI deployments where plugin selection needs to happen at runtime via configuration files rather than at compile time.

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

The plugin chain is fully rebuilt at startup: dependencies are resolved, callbacks are regenerated, and the dispatch module is recompiled. See [Reconfiguration](07a-reconfiguration.md) for more details.

## Service Storage

Each service instance is provided with its own ETS table for storing runtime data. This table is created when the service starts and destroyed when it stops.

See [Storage and State guide](10-storage.md) for details.

## Next Steps

- [Plugins](04-plugins.md) - Understand the plugin system.
- [Callbacks](05-callbacks.md) - Learn more about callback chains.
- [Lifecycle](06-lifecycle.md) - Get a deep dive into the service lifecycle.
- [Configuration](07-configuration.md) - Learn how to configure your services.
- [Reconfiguration](07a-reconfiguration.md) - Learn how to update service configuration at runtime.
