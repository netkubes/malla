# Malla Framework - AI Coding Assistant Instructions

This file is shipped with the Malla Hex package. Import it into your project's
AI instruction file to help coding assistants generate correct Malla code.

## Setup

Add one of these lines to your project's AI instruction file:

- **Claude Code** (`CLAUDE.md`): `@deps/malla/priv/ai/AGENTS.md`
- **OpenAI Codex** (`AGENTS.md`): `@deps/malla/priv/ai/AGENTS.md`
- **Cursor** (`.cursor/rules/malla.md`): copy this file's content
- **Other tools**: reference or copy this file's content into your tool's instruction file

---

## What is Malla?

Malla is an Elixir framework for distributed services with a plugin-based
architecture. Services are composed through compile-time callback chains with
zero runtime overhead.

## Defining a Service

```elixir
defmodule MyApp.MyService do
  use Malla.Service,
    global: true,              # Register in cluster for remote discovery
    plugins: [MyApp.MyPlugin], # Plugins to include
    vsn: "1.0.0"              # Version for compatibility

  # Regular function - callable remotely but NOT in the callback chain
  def my_function(arg), do: {:ok, arg}

  # Callback - participates in the plugin chain (use defcb, not def)
  defcb my_callback(arg) do
    :cont  # Continue to next plugin
  end
end
```

## Defining a Plugin

```elixir
defmodule MyApp.MyPlugin do
  use Malla.Plugin,
    plugin_deps: [MyApp.OtherPlugin]  # Dependencies (optional)

  # Lifecycle callbacks use regular def with @impl true
  @impl true
  def plugin_config(srv_id, config) do
    {:ok, config}
  end

  @impl true
  def plugin_start(srv_id, config) do
    {:ok, children: [MyApp.MyWorker]}  # Supervised children
  end

  @impl true
  def plugin_stop(srv_id, config), do: :ok

  @impl true
  def plugin_updated(_srv_id, old_config, new_config) do
    if old_config[:my_key] != new_config[:my_key] do
      {:ok, restart: true}
    else
      :ok
    end
  end

  # Chain callbacks use defcb
  defcb my_callback(arg) do
    transformed = do_something(arg)
    {:cont, transformed}  # Continue with modified arg
  end
end
```

## Critical Rules

### defcb vs def

- **`defcb`**: Callback in the plugin chain. Must return `:cont`, `{:cont, new_args}`, or a final value.
- **`def`**: Regular Elixir function. Does NOT participate in the chain.
- **Lifecycle callbacks** (`plugin_config/2`, `plugin_start/2`, `plugin_stop/2`, `plugin_updated/3`, `plugin_config_merge/3`) use regular `def` with `@impl true`. They are NOT `defcb`.

### Callback Return Values

| Return Value | Effect |
|---|---|
| `:cont` | Continue to next plugin with same arguments |
| `{:cont, [arg1, arg2]}` | Continue to next plugin with new arguments |
| Any other value | Stop chain, return this value to caller |

### Callback Chain Order

1. **Service module** (top, highest priority, checked first)
2. **Plugins** in dependency order
3. **`Malla.Plugins.Base`** (bottom, default implementations, always present)

### Lifecycle Callback Direction

| Callback | Direction | When |
|---|---|---|
| `plugin_config/2` | Top -> Bottom | Startup |
| `plugin_start/2` | Bottom -> Top | Startup |
| `plugin_updated/3` | Bottom -> Top | Reconfiguration |
| `plugin_stop/2` | Top -> Bottom | Shutdown |

### Plugin Dependencies

- Transitive: if your plugin depends on B and B depends on A, A is included automatically.
- The `plugins:` list in `use Malla.Service` only needs top-level plugins.
- `Malla.Plugins.Base` is always included at the bottom.
- Optional deps: `plugin_deps: [{SomePlugin, optional: true}]`

## Configuration

Services accept config through deep-merged layers:

```elixir
# 1. Static config (in the module)
use Malla.Service,
  my_plugin: [timeout: 5000]

# 2. OTP app config (config.exs / runtime.exs)
use Malla.Service, otp_app: :my_app
# config :my_app, MyService, my_plugin: [timeout: 10000]

# 3. Runtime config (highest precedence)
MyService.start_link(my_plugin: [timeout: 15000])
```

## Remote Calls

```elixir
# Preferred method
Malla.remote(RemoteService, :function_name, [arg1, arg2], timeout: 5000)

# Macro syntax
Malla.call RemoteService.function_name(arg1, arg2), timeout: 5000
```

## Starting Services

```elixir
# Direct
MyService.start_link()

# Under a supervisor
children = [{MyService, [my_plugin: [timeout: 5000]]}]
Supervisor.start_link(children, strategy: :one_for_one)
```

## Built-in Callbacks (from Malla.Plugins.Base)

These callbacks are available in any service. Override them with `defcb`:

```elixir
# React to status changes (always return :cont)
defcb service_status_changed(status) do
  Logger.info("Status: #{status}")
  :cont
end

# Readiness check (return :cont if ready, false if not)
defcb service_is_ready?() do
  if ready?(), do: :cont, else: false
end

# Graceful drain (return :cont if drained, false if still working)
defcb service_drain() do
  if all_done?(), do: :cont, else: false
end
```

## Service Storage (ETS)

Each service gets its own ETS table:

```elixir
Malla.Service.put(MyService, :key, value)
Malla.Service.get(MyService, :key, default)
Malla.Service.del(MyService, :key)
```

## Common Mistakes to Avoid

1. Using `def` instead of `defcb` for chain callbacks (they won't participate in the chain)
2. Using `defcb` for lifecycle callbacks like `plugin_start/2` (use `def` + `@impl true`)
3. Forgetting to return `:cont` from `service_status_changed/1` (blocks other plugins)
4. Returning `true` from `service_is_ready?/0` instead of `:cont`
5. Not including a catch-all `defcb` clause (can cause `FunctionClauseError` in the chain)
6. Declaring all transitive deps in `plugins:` (only top-level needed)

## Code Formatting

Run `mix format` before committing. Malla exports custom formatting rules for
`defcb`, `req`, and `call` macros (no parentheses needed).
