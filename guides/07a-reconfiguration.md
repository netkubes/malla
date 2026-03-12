# Reconfiguration

Malla services support runtime reconfiguration, allowing you to update configuration without restarting the service. This is useful for dynamic parameter tuning, feature flag updates, and adapting to changing operational requirements.

## Overview

Reconfiguration follows the same merge process as initial configuration, but happens while the service is already running. When you call `Malla.Service.reconfigure/2`, the new configuration goes through:

1. **Configuration Merge Phase** (Top → Bottom): Each plugin's `c:Malla.Plugin.plugin_config_merge/3` callback is invoked, allowing custom merge logic
2. **Update Phase** (Bottom → Up): Each plugin's `c:Malla.Plugin.plugin_updated/3` callback is invoked, allowing plugins to react to the changes

## Triggering Reconfiguration

To reconfigure a service, use `Malla.Service.reconfigure/2`, `Malla.Service.add_plugin/2` and `Malla.Service.del_plugin/2`.

```elixir
# Deep-merge new configuration into the existing one
Malla.Service.reconfigure(MyService, my_plugin: [retries: 5])
```

This merges the provided configuration with the current configuration and triggers the reconfiguration callbacks.

## The Reconfiguration Process

### 1. Configuration Merge Phase (Top → Bottom)

When reconfiguration is triggered, `c:Malla.Plugin.plugin_config_merge/3` is called for each plugin from the service module down to base plugins. This is the same callback used during initial configuration.

```elixir
defmodule MyPlugin do
  use Malla.Plugin

  @impl Malla.Plugin
  def plugin_config_merge(srv_id, old_config, new_config) do
    # Custom merge logic for this plugin's configuration
    merged = deep_merge(old_config, new_config)
    
    # Validate the merged config
    case validate_config(merged) do
      :ok -> {:ok, merged}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

**Key Points:**
- Called in **top-to-bottom** order (service → plugin1 → plugin2 → base)
- Receives both the old and new configuration
- Can implement custom merge logic (default is deep merge)
- Can reject invalid configurations by returning `{:error, reason}`
- The same callback is used for both initial configuration and reconfiguration

### 2. Update Phase (Bottom → Up)

After configuration is merged, `c:Malla.Plugin.plugin_updated/3` is called for each plugin from base plugins up to the service module. This allows plugins to react to configuration changes.

```elixir
defmodule MyPlugin do
  use Malla.Plugin

  @impl Malla.Plugin
  def plugin_updated(srv_id, old_config, new_config) do
    # Check what changed
    if config_requires_restart?(old_config, new_config) do
      # Request a full service restart
      {:restart, :configuration_changed}
    else
      # Apply changes dynamically
      apply_config_changes(old_config, new_config)
      :ok
    end
  end
end
```

**Key Points:**
- Called in **bottom-to-up** order (base → plugin2 → plugin1 → service)
- Receives both old and new configuration
- Can return `:ok` to accept changes without restart
- Can return `{:restart, reason}` to request a full service restart
- If any plugin requests restart, the service will restart with the new configuration

## Dynamic vs. Restart-Required Changes

Plugins can handle configuration changes in two ways:

### Dynamic Updates (No Restart)

Some configuration changes can be applied without restarting the service:

```elixir
def plugin_updated(_srv_id, old_config, new_config) do
  # Update timeout dynamically
  old_timeout = get_in(old_config, [:my_plugin, :timeout])
  new_timeout = get_in(new_config, [:my_plugin, :timeout])
  
  if old_timeout != new_timeout do
    update_timeout(new_timeout)
  end
  
  :ok
end
```

**Examples of dynamic changes:**
- Timeout values
- Retry counts
- Log levels
- Rate limits
- Feature flags

### Restart-Required Changes

Some configuration changes require a full restart to take effect:

```elixir
def plugin_updated(_srv_id, old_config, new_config) do
  # Check if connection settings changed
  old_host = get_in(old_config, [:my_plugin, :host])
  new_host = get_in(new_config, [:my_plugin, :host])
  
  if old_host != new_host do
    {:ok, restart: true}
  else
    :ok
  end
end
```

**Examples of restart-required changes:**
- Connection endpoints (host, port)
- Database pool size
- TLS/SSL configuration
- Supervised child specifications
- Plugin additions/removals

## Runtime Plugin Specification at Startup

You can specify the plugin list at startup by passing `plugins:` to `start_link/1`. This replaces the compile-time plugin list entirely and is processed before any configuration merging:

```elixir
# Service with no compile-time plugins
defmodule MyService do
  use Malla.Service, global: true
end

# At runtime, load plugins from a config file and start with them
plugins = Application.get_env(:my_app, :plugins, [])
{:ok, pid} = MyService.start_link(plugins: plugins, my_setting: :value)
```

This uses the same infrastructure as `add_plugin/3` and `del_plugin/2` — the plugin chain is rebuilt via dependency resolution, callbacks are regenerated, and the dispatch module is recompiled at startup. The remaining configuration keys (everything except `plugins:`) are then processed through the new plugin chain.

You can also pass `plugins:` to `Malla.Service.reconfigure/2` to replace the plugin list on an already-running service:

```elixir
Malla.Service.reconfigure(MyService, plugins: [NewPlugin], new_plugin: [key: :value])
```

### Use Cases

- **Escript/CLI deployments**: Plugin selection from config files instead of compile-time declarations
- **Testing**: Try different plugin combinations without recompiling
- **Multi-tenant services**: Different plugin sets per service instance

## Runtime Plugin Management

One of Malla's **most powerful features** is the ability to add or remove plugins at runtime **without touching your code**. This is a game-changer for production operations:

- **Debugging in Production**: Add a tracing or logging plugin to a live service to investigate issues, then remove it once resolved
- **Feature Rollout**: Gradually enable new functionality by adding plugins to running services
- **Emergency Response**: Quickly disable problematic features by removing their plugins without code deployment
- **A/B Testing**: Dynamically swap plugin implementations to test different behaviors
- **Zero-Downtime Updates**: Update service behavior without stopping traffic

```elixir
# Production service is having issues - add detailed tracing plugin remotely
Malla.Service.add_plugin(MyService, NewPlugin, config: [new_plugin: my_config])

# Investigate the issue with enhanced tracing...

# Remove the tracing plugin once the issue is resolved
Malla.Service.del_plugin(MyService, NewPlugin)
```

All without deploying new code, recompiling, or taking the service offline. The service restarts with the new plugin configuration automatically.

### Adding Plugins

To add a plugin at runtime, use `Malla.Service.add_plugin/3`:

**What happens when a plugin is added:**
1. The service's plugin chain is rebuilt with the new plugin included
2. `c:Malla.Plugin.plugin_config_merge/3` is called for the new plugin
3. Dispatcher module is recompiled son new callbacks are inserted
4. `c:Malla.Plugin.plugin_start/2` is called for the new plugin during restart

### Removing Plugins

To remove a plugin, use the use `Malla.Service.del_plugin/2`:

**What happens when a plugin is removed:**
1. The service's plugin chain is rebuilt without the removed plugin
3. `c:Malla.Plugin.plugin_stop/2` is called for the removed plugin during restart
4. The plugin's callbacks are no longer available in the callback chain


## Related Topics

- [Configuration](07-configuration.md) - Learn about initial configuration layers
- [Lifecycle](06-lifecycle.md) - Understanding the full service lifecycle including reconfiguration
- [Plugins](04-plugins.md) - Learn how to implement lifecycle callbacks in plugins
