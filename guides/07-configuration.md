# Configuration

Malla provides a multi-layered system for configuring services. Configuration is merged from several sources, allowing you to set defaults statically in your code and override them for different environments or at runtime.

This guide covers the configuration of **services** and, at the end, the `config :malla` settings of the framework itself.

## Configuration Layers

Configuration is built from layers, merged in a specific order. Plugins take part in each merge through the `c:Malla.Plugin.plugin_config_merge/3` callback.

The base configuration layers are merged in the following order (later layers win):
1.  **Static Configuration** (in the `use Malla.Service` of the service module)
2.  **OTP Application Configuration** (from `config.exs`/`runtime.exs`, if `otp_app` is set)
3.  **Runtime Configuration** (passed to `start_link/1`)

### How Configuration Merging Works

When a service starts, in the service process:

1. **Static Configuration** is the starting point.
2. **OTP Application Configuration** (if `otp_app` is specified): the environment `Application.get_env(otp_app, MyService, [])` is merged with the static configuration. `c:Malla.Plugin.plugin_config_merge/3` is called for each plugin from top to bottom, and then the layer is deep-merged on top of what the plugins returned.
3. **Runtime Configuration** (from `start_link/1`): the same process, with the options you passed (except `plugins:`, which is taken out first: see below).
4. The service callback `service_config/1` (see [Callbacks](05-callbacks.md)) is called with the result, and then `c:Malla.Plugin.plugin_config/2` is called for each plugin from top to bottom with the configuration they must validate and may modify.

So if both OTP app config and runtime config are provided, `plugin_config_merge/3` is called twice, once per layer. Each plugin can implement custom merge logic, or rely on the default deep merge, which is applied after the plugins.

### Deep Merge

The default merge is `Keyword.merge/3` where, when both values are **keyword lists**, they are merged recursively. Any other value (a map, a list that is not a keyword list, a number, ...) is **replaced** by the update. So:

```elixir
# static:  my_plugin: [timeout: 5000, retries: 3]
# update:  my_plugin: [retries: 5]
# result:  my_plugin: [timeout: 5000, retries: 5]

# static:  limits: %{max: 10, min: 1}
# update:  limits: %{max: 20}
# result:  limits: %{max: 20}          # the map is replaced, not merged
```

Prefer keyword lists for the configuration that you want to update partially.

## 1. Static Configuration

Pass any key-value pairs to `use Malla.Service`, and they become part of the service's static configuration.

```elixir
defmodule MyService do
  use Malla.Service,
    # By convention, use a key named after the plugin you are configuring
    my_plugin: [timeout: 5000, retries: 3]
end
```

Some keys are not configuration but options of the service itself: `:class`, `:vsn`, `:global`, `:paused`, `:silent`, `:priority`, `:plugins` and `:otp_app`. See [Services](03-services.md).

## 2. OTP Application Configuration

To load configuration from your application's environment (e.g., `config/config.exs`, `config/runtime.exs`), use the `otp_app` option.

```elixir
# In your service:
defmodule MyService do
  use Malla.Service, otp_app: :my_app
end

# In config/runtime.exs:
import Config

config :my_app, MyService,
  my_plugin: [
    # This value will override the static configuration
    timeout: 10000
  ]
```

Malla looks for a key matching the service's module name (`MyService`) in the specified OTP application's (`:my_app`) environment.

## 3. Runtime Configuration

You can provide configuration when starting a service. This is the highest-precedence layer at start.

```elixir
# When starting directly
MyService.start_link(my_plugin: [timeout: 15000])

# When starting in a supervisor
children = [
  {MyService, [my_plugin: [timeout: 15000]]}
]
```

You can also specify the plugin list at runtime, replacing the compile-time plugins entirely:

```elixir
# Override plugins and provide their configuration
MyService.start_link(
  plugins: [MyPlugin, AnotherPlugin],
  my_plugin: [timeout: 15000]
)
```

The `plugins:` key is extracted before configuration merging. The plugin chain is rebuilt first, then the remaining configuration keys are processed through the new plugin chain's `plugin_config_merge/3` and `plugin_config/2` callbacks.

### Keys that are refused

A runtime layer (the `start_link/1` options, the `otp_app` environment or a `reconfigure/2` update) cannot carry `:class`, `:vsn`, `:global`, `:paused`, `:silent`, `:priority` or `:otp_app`. The service refuses it with `{:error, {:key_not_allowed_in_service_start, key}}`; at startup, `start_link/1` fails with that reason.

## Reading the Configuration

```elixir
MyService.get_config()               # same as Malla.Service.get_config(MyService)
# => [my_plugin: [timeout: 15000, retries: 3]]
```

The value is the configuration after every plugin's `plugin_config/2`; it is cached, and it is `:unknown` if the service is not running. Inside a callback you usually get the service ID with `Malla.get_service_id!/0`; inside the lifecycle callbacks the service ID and configuration are passed as arguments.

## Runtime Reconfiguration

Services can be reconfigured at runtime without stopping them:

```elixir
# Deep-merge new configuration into the existing one
Malla.Service.reconfigure(MyService, my_plugin: [retries: 5])
```

Reconfiguration goes through the same merge, triggering `c:Malla.Plugin.plugin_config_merge/3`, `c:Malla.Plugin.plugin_config/2` and `c:Malla.Plugin.plugin_updated/3`. For a comprehensive guide, including adding and removing plugins, see the [Reconfiguration guide](07a-reconfiguration.md).

## Node-wide Store

For node-wide values that are not tied to a specific service, Malla provides a simple ETS-based key-value store, `Malla.Config`. It lives as long as the `:malla` application, so it survives service restarts, and it is local to each node.

```elixir
Malla.Config.put(:my_app, :global_setting, "value")
Malla.Config.get(:my_app, :global_setting, "default")
```

See [Storage and State](10-storage.md).

## Settings of the `:malla` Application

These are the keys read from the `:malla` application environment. All of them are optional.

| Key | Default | Read | What it does |
| :--- | :--- | :--- | :--- |
| `:connect` | `[]` | every 5 s, by `Malla.Cluster` | List of node entries (`"name@domain"` or `"domain"` strings) that `Malla.Cluster.connect/1` tries to connect to. It does nothing unless you add `Malla.Cluster` to your supervision tree. See [Cluster Setup](08-distribution/01-cluster-setup.md). |
| `:cluster` | `""` | once, when the `:malla` application starts | A cluster name. It is only added as the `cluster` entry of the metadata that `Malla.get_service_meta/1` returns, which `Malla.metric/4` merges into the telemetry metadata. It does not segregate nodes. |
| `:remote_timeout` | `15_000` | on every `Malla.remote/4` call | Default timeout, in milliseconds, of `Malla.remote/4` (and so of the `call` macro, virtual modules and `Malla.Request`). Overridden by the `:timeout` option of the call. |
| `:log_min_level` | `:min` | at compile time, when `Malla.Tracer` log macros are expanded | Log macros (`debug/2`, `info/2`, ...) below this level are removed from the compiled code. Levels, lowest first: `:min`, `:debug`, `:metric`, `:info`, `:event`, `:notice`, `:warning`, `:error`, `:max`. Recompile the modules that use `Malla.Tracer` after changing it. |
| `:precompile` | none | once, when the `:malla` application starts | List of `{service_module, [callback_name: arity]}`. For each one Malla creates, at startup, a stub module whose functions answer `{:error, :malla_service_not_available}` until the service is discovered on another node. See [Service Discovery](08-distribution/02-service-discovery.md). |
| `:default_service_id` | none | whenever `Malla.get_service_id!/0` finds no service ID in the process dictionary | A service module to use then. Malla logs a warning, stores it in the process dictionary and returns it. Without it, `Malla.ServiceIdMissing` is raised. |

```elixir
# config/runtime.exs
import Config

config :malla,
  connect: ["myapp@myapp-headless.default.svc.cluster.local"],
  remote_timeout: 20_000,
  default_service_id: MyApp.MainService
```

`:log_min_level` is a compile-time setting, so put it in `config/config.exs` or `config/prod.exs`:

```elixir
config :malla, log_min_level: :info
```

Only the log macros below that level disappear from the compiled code. Every other call of `Malla.Tracer` (spans, metrics, events, `error/1`, ...) still calls the tracer callbacks.
