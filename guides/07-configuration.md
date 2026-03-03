# Configuration

Malla provides a flexible, multi-layered system for configuring services. Configuration is deep-merged from several sources, allowing you to set defaults statically in your code and override them for different environments or at runtime.

## Configuration Layers

Configuration is built from multiple layers, merged in a specific order. Each layer is processed sequentially, and plugins participate in the merge process through the `c:Malla.Plugin.plugin_config_merge/3` callback.

The base configuration layers are merged in the following order:
1.  **Static Configuration** (in the service module)
2.  **OTP Application Configuration** (from `config.exs`)
3.  **Runtime Configuration** (passed to `start_link/1`)

### How Configuration Merging Works

When a service starts or reconfigures, each configuration layer triggers a top-down merge phase:

1. **Static Configuration** is established first
2. **OTP Application Configuration** (if `otp_app` is specified): `c:Malla.Plugin.plugin_config_merge/3` is called for each plugin from top to bottom, allowing plugins to customize how their configuration is merged
3. **Runtime Configuration** (from `start_link/1`): `c:Malla.Plugin.plugin_config_merge/3` is called again for each plugin from top to bottom

This means that if both OTP app config and runtime config are provided, `c:Malla.Plugin.plugin_config_merge/3` is invoked twice—once for each layer. Each plugin can implement custom merge logic, or rely on the default deep merge behavior.

**Important**: Later layers don't simply "override" earlier ones. Instead, each layer goes through the plugin merge process, allowing fine-grained control over how configuration is combined.

## 1. Static Configuration

You can define default configuration directly in your service module using the `use Malla.Service` macro or the `config` macro.

You can pass any key-value pairs to `use Malla.Service`, and they will become part of the service's static configuration.

```elixir
defmodule MyService do
  use Malla.Service,
    # By convention, use a key named after the plugin you are configuring
    my_plugin: [timeout: 5000, retries: 3]
end
```

## 2. OTP Application Configuration

To load configuration from your application's environment (e.g., `config/config.exs`, `config/runtime.exs`), you can use the `otp_app` option.

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

Malla will look for a key matching the service's module name (`MyService`) in the specified OTP application's (`:my_app`) environment.

## 3. Runtime Configuration

You can provide configuration when starting a service. This is the highest-precedence layer and will override all other configurations.

```elixir
# When starting directly
MyService.start_link(my_plugin: [timeout: 15000])

# When starting in a supervisor
children = [
  {MyService, [my_plugin: [timeout: 15000]]}
]
```

## Runtime Reconfiguration

Services can be reconfigured at runtime without stopping them. This allows you to update configuration dynamically in response to changing requirements.

```elixir
# Deep-merge new configuration into the existing one
Malla.Service.reconfigure(MyService, my_plugin: [retries: 5])
```

Reconfiguration follows the same merge process as initial configuration, triggering `c:Malla.Plugin.plugin_config_merge/3` and `c:Malla.Plugin.plugin_updated/3` callbacks. Some configuration changes can be applied dynamically, while others may require a service restart.

For a comprehensive guide to reconfiguration, including adding/removing plugins and handling dynamic vs. restart-required changes, see the [Reconfiguration guide](07a-reconfiguration.md).

## Global Configuration Store

For node-wide configuration that is not tied to a specific service, Malla provides a simple ETS-based key-value store via the `Malla.Config` module. This store survives service restarts but is local to each node.

```elixir
# Store a global setting
Malla.Config.put(:my_app, :global_setting, "value")

# Retrieve the setting
Malla.Config.get(:my_app, :global_setting, "default")
```
This is useful for application-wide settings that need to be accessed from multiple places.
