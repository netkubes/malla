# AGENTS.md

Instructions for AI coding assistants working with the Malla framework codebase.

## Project Overview

Malla is a framework for developing distributed services in Elixir networks. It simplifies distributed service development through a plugin-based architecture with compile-time callback chaining, automatic service discovery across nodes, and minimal "magic" to keep systems understandable.

## Common Commands

```bash
mix deps.get          # Get dependencies
mix compile           # Compile the project
mix format            # Format code (custom rules for defcb, req, call)
mix test              # Run tests
mix test test/service1_plugins_test.exs  # Run a specific test file
mix docs              # Generate documentation
iex -S mix            # Start an interactive shell
```

### Distributed Testing

```bash
# Terminal 1
iex --sname first --cookie malla_dev -S mix

# Terminal 2
iex --sname second --cookie malla_dev -S mix
# Then: Node.connect(:"first@<hostname>")
```

## Core Architecture

### Plugin System with Compile-Time Callback Chaining

Malla's architecture centers on a plugin system where behavior is composed through callback chains resolved at compile time (zero runtime overhead).

**Callback Chain Flow:**
1. Service modules (using `Malla.Service`) are themselves plugins
2. Dependencies form a hierarchy: `Malla.Plugins.Base` (bottom) -> plugins -> your service module (top)
3. Each callback invocation walks the chain from top to bottom until a plugin returns a non-`:cont` value
4. Plugins can return:
   - `:cont` - continue to next plugin with same args
   - `{:cont, new_args}` or `{:cont, arg1, arg2}` - continue with modified args
   - Any other value - stop chain and return that value

**Callback Definition:**
- Use `defcb` instead of `def` for callbacks that participate in the chain
- Original implementation is renamed to `{name}_malla_service`
- Final dispatching version is generated in `Module.MallaDispatch` submodule

**Plugin Dependencies:**
- Declare with `use Malla.Plugin, plugin_deps: [OtherPlugin]`
- Optional dependencies: `plugin_deps: [{Plugin, optional: true}]`
- Plugin groups ensure ordering: `use Malla.Plugin, group: :my_group`

### Service Lifecycle

Services have admin status (`:active`, `:pause`, `:inactive`) and running status (`:starting`, `:running`, `:paused`, `:stopped`, `:failed`).

**Lifecycle callbacks** (standard Elixir callbacks, NOT in the defcb chain):
1. `plugin_config/2` - Top-level to bottom, each plugin can modify config for dependants
2. `plugin_start/2` - Bottom to top, returns child_spec for supervised children
3. `plugin_updated/3` - On reconfiguration, can trigger restart
4. `plugin_stop/2` - Top to bottom, cleanup before children are stopped

### Distributed Service Discovery

- Services with `global: true` join process group `Malla.Services2` via `:pg`
- Periodic health checks every 10 seconds track available services
- `get_nodes/1` returns nodes running a service (local node first, rest randomized)
- RPC via `call_cb/4` automatically routes to available nodes with failover
- Virtual modules are created dynamically for transparent remote calls

### Key Modules

- **Malla.Service** - Main service behavior and `use` macro, compiles plugin chains
- **Malla.Plugin** - Plugin behavior and `defcb` macro
- **Malla.Service.Server** - GenServer managing service lifecycle and status
- **Malla.Service.Make** - Builds service structure from use_spec and callbacks
- **Malla.Service.Build** - Generates optimized callback dispatch code
- **Malla.Service.TopSort** - Topological sort for plugin dependency ordering
- **Malla.Node** - Service discovery and RPC across cluster
- **Malla.Cluster** - Node connection utilities via DNS/SRV
- **Malla.Config** - ETS-based global config store
- **Malla.Plugins.Base** - Base plugin all services depend on, provides fundamental callbacks

### Service Storage and State

Each service gets an ETS table (named after the service module) for runtime data:
- `Malla.Service.get/3`, `put/3`, `put_new/3`, `del/2`
- Table destroyed when service stops
- Service ID stored in process dictionary via `Malla.put_service_id/1`

### Configuration

Services are configured through deep-merged layers:
1. Static config in `use Malla.Service, key: value`
2. OTP app config (if `otp_app:` is specified)
3. Runtime config in `start_link/1` or supervisor `child_spec/1`
4. Remote config via `from_plugin:` option

Plugin config macro supports:
- `config key: value` - adds to root config
- `config PluginName, opt: value` - namespaced config

## Code Patterns

### Defining a Service

```elixir
defmodule MyApp.MyService do
  use Malla.Service,
    global: true,
    plugins: [MyApp.SomePlugin],
    vsn: "1.0.0"

  # Regular function - available remotely but not in callback chain
  def my_function(arg), do: {:ok, arg}

  # Callback - participates in plugin chain
  defcb my_callback(arg) do
    # do work
    :cont  # or return a value to stop chain
  end
end
```

### Defining a Plugin

```elixir
defmodule MyApp.MyPlugin do
  use Malla.Plugin,
    plugin_deps: [MyApp.BasePlugin]

  # Lifecycle callbacks (standard Elixir callbacks, NOT defcb)
  @impl true
  def plugin_config(srv_id, config) do
    {:ok, updated_config}
  end

  @impl true
  def plugin_start(srv_id, config) do
    {:ok, children: [MyWorker]}
  end

  @impl true
  def plugin_stop(srv_id, config) do
    :ok
  end

  @impl true
  def plugin_updated(_srv_id, old_config, new_config) do
    if old_config[:my_key] != new_config[:my_key] do
      {:ok, restart: true}
    else
      :ok
    end
  end

  # Callbacks that participate in the chain (use defcb, not def)
  defcb some_callback(arg) do
    :cont
  end
end
```

### Plugin with Supervised Children

```elixir
defmodule MyApp.DatabasePlugin do
  use Malla.Plugin

  defmodule Pool do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def init(opts), do: {:ok, opts}
  end

  @impl true
  def plugin_start(_srv_id, config) do
    {:ok, children: [{Pool, config[:database]}]}
  end

  @impl true
  def plugin_stop(_srv_id, _config) do
    :ok
  end

  defcb service_is_ready?() do
    case Malla.Service.get(__MODULE__, :pool_ready) do
      true -> :cont
      _ -> false
    end
  end
end
```

### Callback Chain Example

```elixir
# Bottom of chain - provides default behavior
defmodule MyApp.ValidationPlugin do
  use Malla.Plugin

  defcb process(data) do
    if valid?(data), do: :cont, else: {:error, :invalid}
  end
end

# Middle of chain - transforms data
defmodule MyApp.TransformPlugin do
  use Malla.Plugin,
    plugin_deps: [MyApp.ValidationPlugin]

  defcb process(data) do
    {:cont, transform(data)}
  end
end

# Top of chain - service decides what to do
defmodule MyApp.MyService do
  use Malla.Service,
    plugins: [MyApp.TransformPlugin]

  # Handle specific case at service level
  defcb process(:special) do
    {:ok, :handled_specially}
  end

  # For everything else, continue to plugins
  defcb process(_data) do
    :cont
  end
end

# Chain order: MyService -> TransformPlugin -> ValidationPlugin -> Base
```

### Remote Service Calls

```elixir
# Direct callback invocation (preferred)
Malla.remote(RemoteService, :my_function, [arg1, arg2], timeout: 5000)

# Using the call macro
Malla.call RemoteService.my_function(arg1, arg2), timeout: 5000

# Call all nodes implementing a service
Malla.Node.call_cb_all(RemoteService, :callback_name, [args])
```

### Starting Services

```elixir
# Direct start
{:ok, pid} = MyService.start_link()

# With runtime configuration
{:ok, pid} = MyService.start_link(my_plugin: [timeout: 5000])

# Under a supervisor
children = [
  {MyService, [my_plugin: [timeout: 5000]]}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

### Status and Readiness

```elixir
# Implement readiness check in a plugin
defcb service_is_ready?() do
  if my_resource_ready?(), do: :cont, else: false
end

# Implement graceful drain
defcb service_drain() do
  if all_work_complete?(), do: :cont, else: false
end

# Implement status change monitoring
defcb service_status_changed(status) do
  Logger.info("Status: #{status}")
  :cont  # Always return :cont to let other plugins be notified
end
```

## Testing Notes

- Test files in `test/` directory
- `test/test_helper.exs` sets up test environment
- Key test files:
  - `service1_plugins_test.exs` - Plugin functionality
  - `top_sort_test.exs` - Dependency ordering
  - `service_management_test.exs` - Service lifecycle
  - `call_test.exs` - Remote calls
- Test plugin examples in `test/support/` directory

## Code Formatting

The `.formatter.exs` configures special handling for Malla-specific macros:
- `defcb` (with and without do-block)
- `req` and `call` (request-related macros)

Always run `mix format` before committing.

## Critical Rules

### defcb vs def
- **`defcb`** = callback that participates in the plugin chain. Returns `:cont`, `{:cont, args}`, or a final value.
- **`def`** = regular Elixir function. Does NOT participate in the chain.
- **Lifecycle callbacks** (`plugin_config/2`, `plugin_start/2`, `plugin_stop/2`, `plugin_updated/3`, `plugin_config_merge/3`) use regular `def` with `@impl true`, NOT `defcb`.

### Return Values in defcb
- `:cont` = pass to next plugin with same args
- `{:cont, [arg1, arg2]}` = pass to next plugin with new args
- Anything else = stop chain, return this value to caller

### Plugin Dependencies
- Transitive: declaring `plugin_deps: [B]` where B depends on A automatically includes A
- The service module's `plugins:` list only needs to include the top-level plugins
- `Malla.Plugins.Base` is always included automatically at the bottom

### Callback Chain Order
- Top = service module (highest priority, checked first)
- Middle = plugins in dependency order
- Bottom = `Malla.Plugins.Base` (default implementations)

### Lifecycle Callback Direction
- `plugin_config/2` and `plugin_stop/2` run top-down (service first)
- `plugin_start/2` and `plugin_updated/3` run bottom-up (deepest dependency first)

## Important Considerations

### When Modifying the Plugin System
- Changes to `Malla.Service.Make` affect how plugin chains are built at compile time
- Changes to `Malla.Service.Build` affect generated dispatch code
- Plugin ordering via `TopSort` is critical - maintains dependency contracts
- Callback signatures must match across all plugins in a chain
- The three-stage compilation process (requires -> main -> modules) must be preserved

### When Adding New Callbacks
- Define with `defcb` in the plugin that provides base implementation
- Document the callback contract (what `:cont` means, what return values mean)
- Consider what happens if multiple plugins implement it
- Callback is registered in `@plugin_callbacks` module attribute

### Distributed Behavior
- Service discovery is eventually consistent (10-second refresh)
- RPC calls have 30-second default timeout
- Local node is always preferred in `get_nodes/1` results
- Virtual modules are created dynamically via `maybe_make_module/2`

### Service Status Management
- Status cached in `:persistent_term` for fast reads
- Status changes trigger plugin lifecycle callbacks
- Failed services automatically retry startup
- Use `set_admin_status/2` for controlled state transitions
