# Reconfiguration

Malla services support runtime reconfiguration, allowing you to update configuration, and the plugins of a service, without restarting it. This is useful for parameter tuning, feature flag updates, and adapting to changing operational requirements.

## Overview

Reconfiguration follows the same merge process as the initial configuration, but happens while the service is already running. When you call `Malla.Service.reconfigure/2`, the new configuration goes through:

1. **Configuration Merge Phase** (Top → Bottom): each plugin's `c:Malla.Plugin.plugin_config_merge/3` callback is invoked, allowing custom merge logic. The update is then deep-merged on top of the result.
2. **Configuration Phase** (Top → Bottom): each plugin's `c:Malla.Plugin.plugin_config/2` is invoked with the merged configuration, to validate or adjust it.
3. **Update Phase** (Bottom → Top): each plugin's `c:Malla.Plugin.plugin_updated/3` callback is invoked, allowing plugins to react to the changes.

## Triggering Reconfiguration

To reconfigure a service, use `Malla.Service.reconfigure/2` (or `MyService.reconfigure/1`), `Malla.Service.add_plugin/3` and `Malla.Service.del_plugin/2`.

```elixir
# Deep-merge new configuration into the existing one
Malla.Service.reconfigure(MyService, my_plugin: [retries: 5])
```

This merges the provided configuration with the current configuration and triggers the reconfiguration callbacks. The call returns `:ok`, or `{:error, reason}`.

If the service has the `otp_app` option, its application environment (`Application.get_env(otp_app, MyService)`) is applied again first, and your update is applied on top of it.

The same restrictions as at startup apply: an update that carries `:class`, `:vsn`, `:global`, `:paused`, `:silent`, `:priority` or `:otp_app` is refused with `{:error, {:key_not_allowed_in_service_start, key}}`.

## The Reconfiguration Process

### 1. Configuration Merge Phase (Top → Bottom)

When reconfiguration is triggered, `c:Malla.Plugin.plugin_config_merge/3` is called for each plugin from the service module down to `Malla.Plugins.Base`. This is the same callback used during the initial configuration. It receives the service ID, the **whole current configuration** and the **update** (just the keys you passed, not the merged result).

```elixir
defmodule MyPlugin do
  use Malla.Plugin

  @impl true
  def plugin_config_merge(_srv_id, _old_config, update) do
    # Reject an update we do not accept. Return :ok to leave it to the default merge.
    case Keyword.get(update, :my_plugin, []) do
      opts when is_list(opts) ->
        if Keyword.get(opts, :retries, 0) < 0,
          do: {:error, :negative_retries},
          else: :ok

      _ ->
        {:error, :my_plugin_must_be_a_keyword_list}
    end
  end
end
```

**Key Points:**
- Called in **top-to-bottom** order (service → plugin1 → plugin2 → base).
- Return `:ok` to let the next plugin (and finally the default deep merge) do the merge.
- Return `{:error, reason}` to reject the update: `reconfigure/2` returns `{:error, reason}` and the configuration is not changed.
- Return `{:ok, merged_config}` to hand a modified *current configuration* to the next plugin. The **update is still deep-merged on top** of what the last plugin returned, so a plugin cannot change or drop a key that the update carries: it can only adjust the other keys. If you need to turn an update into something else, validate it with `{:error, ...}` or normalize it in `plugin_config/2`, which sees the merged result.
- The same callback is used for the initial configuration (once per layer) and for reconfiguration.
- Without a custom `plugin_config_merge/3`, the default deep merge is used: nested **keyword lists** are merged key by key, other values (maps, plain lists, scalars) are replaced by the update.

### 2. Configuration Phase (Top → Bottom)

After the merge, `c:Malla.Plugin.plugin_config/2` is called for each plugin, from the service down, with the merged configuration. A plugin can return `:ok`, `{:ok, new_config}` (a keyword list) or `{:error, reason}`. On an error the whole reconfiguration is rejected.

### 3. Update Phase (Bottom → Top)

After the configuration is final, `c:Malla.Plugin.plugin_updated/3` is called for each plugin from the base plugins up to the service module. This allows plugins to react to configuration changes.

```elixir
defmodule MyPlugin do
  use Malla.Plugin

  @impl true
  def plugin_updated(_srv_id, old_config, new_config) do
    # Check what changed
    if old_config[:my_plugin][:host] != new_config[:my_plugin][:host] do
      # Restart this plugin
      {:ok, restart: true}
    else
      :ok
    end
  end
end
```

**Key Points:**
- Called in **bottom-to-top** order (base → plugin2 → plugin1 → service).
- Receives both the old and the new configuration.
- Returns `:ok` to accept the changes.
- Returns `{:ok, restart: true}` to restart **that plugin only**: Malla stops the supervisor of its children and calls `c:Malla.Plugin.plugin_start/2` again with the new configuration. `c:Malla.Plugin.plugin_stop/2` is *not* called for this restart. The service and the other plugins keep running.
- Returns `{:error, reason}` to report a failure: the remaining plugins are not called and `reconfigure/2` returns `{:error, reason}`. The new configuration stays applied: the error does not roll it back.

## Dynamic vs. Restart-Required Changes

Plugins can handle configuration changes in two ways:

### Dynamic Updates (No Restart)

Some configuration changes can be applied without restarting anything. The plugin reads the configuration when it needs it (`srv_id.get_config()`), or reacts in `plugin_updated/3`:

```elixir
def plugin_updated(srv_id, old_config, new_config) do
  # Tell a running worker about the new timeout
  old_timeout = get_in(old_config, [:my_plugin, :timeout])
  new_timeout = get_in(new_config, [:my_plugin, :timeout])

  if old_timeout != new_timeout do
    MyPlugin.Worker.set_timeout(srv_id, new_timeout)
  end

  :ok
end
```

### Changes That Need the Plugin to Restart

Some configuration changes need the plugin's children to be started again with the new values:

```elixir
def plugin_updated(_srv_id, old_config, new_config) do
  if old_config[:my_plugin][:host] != new_config[:my_plugin][:host] do
    {:ok, restart: true}
  else
    :ok
  end
end
```

Typical cases: connection endpoints (host, port), pool sizes, TLS settings, or the child specs that `plugin_start/2` returns. `Malla.Plugins.Httpd` does this when `:malla_httpd` changes.

You can also restart a plugin from outside, at any time, with `Malla.Service.restart_plugin/2`. It is asynchronous (a cast to the service) and does nothing if the plugin has not started.

```elixir
Malla.Service.restart_plugin(MyService, MyPlugin)
```

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

This uses the same machinery as `add_plugin/3` and `del_plugin/2`: the plugin chain is rebuilt with its dependencies, callbacks are regenerated and the dispatch module is recompiled. The remaining configuration keys (everything except `plugins:`) are then processed through the new plugin chain.

You can also pass `plugins:` to `Malla.Service.reconfigure/2` to replace the plugin list of a running service:

```elixir
Malla.Service.reconfigure(MyService, plugins: [NewPlugin], new_plugin: [key: :value])
```

The chain and the dispatch module change immediately. The plugins that this adds are started, and the ones it removes are stopped, by the next periodic check of the service, which runs every 5 seconds. (`add_plugin/3` and `del_plugin/2`, below, ask for that check right away.)

If the plugins cannot be resolved (for example, a module that does not exist), the call returns `{:error, exception}` (the exception that was raised while building the chain) and the previous chain is kept.

## Runtime Plugin Management

Plugins can be added to or removed from a running service without touching your code. Some uses:

- **Debugging in production**: add a tracing or logging plugin to a live service to investigate an issue, then remove it.
- **Feature rollout**: enable new functionality by adding a plugin to a running service.
- **Emergency response**: disable a problematic feature by removing its plugin.

```elixir
# Add a tracing plugin to a running service
Malla.Service.add_plugin(MyService, NewPlugin, config: [new_plugin: [level: :debug]])

# Investigate the issue...

# Remove the plugin once the issue is resolved
Malla.Service.del_plugin(MyService, NewPlugin)
```

**The service is not restarted** by either call. The callback chain and the dispatch module are rebuilt, and the plugin is started or stopped inside the running service.

### Adding Plugins

To add a plugin at runtime, use `Malla.Service.add_plugin/3`:

**What happens when a plugin is added:**
1. The service's plugin chain is rebuilt with the new plugin included (it is put first in the list of `plugins`, so among independent plugins it is called first), and the dispatch module is recompiled, so the new callbacks are in effect immediately.
2. If you pass `config:`, the configuration goes through `c:Malla.Plugin.plugin_config_merge/3` and `c:Malla.Plugin.plugin_config/2` of the plugins of the chain (the new one included). Without `config:`, neither is called for the new plugin. `plugin_updated/3` is not called in either case.
3. The service then runs a status check immediately, which calls `c:Malla.Plugin.plugin_start/2` for the new plugin (when the service is `:running`; otherwise it is started when the service becomes active). Its dependencies that were not in the chain are started too, dependencies first.

`add_plugin/3` returns `:ok` if the plugin is already in the service's `plugins` list (nothing is done). It returns `{:error, reason}` if the chain cannot be built, or if `config:` is rejected; in both cases the service keeps its previous chain.

If the new plugin fails to start, the service becomes `:failed`, as described in the [Lifecycle guide](06-lifecycle.md), but only the plugins started in this round are stopped; the ones that were already running keep running.

### Removing Plugins

To remove a plugin, use `Malla.Service.del_plugin/2`:

**What happens when a plugin is removed:**
1. The service's plugin chain is rebuilt without the removed plugin and the dispatch module is recompiled: its callbacks are no longer in any chain.
2. A status check runs right after the call returns, which calls `c:Malla.Plugin.plugin_stop/2` of the removed plugin and then stops its children supervisor.

`del_plugin/2` only removes plugins listed in the service's `plugins`. For a plugin that is not there, including one that is only part of the chain as a dependency of another plugin, it returns `:ok` and does nothing. If another plugin of the list still depends on the removed one, the dependency stays in the chain.

> The rebuilt chain, with the configuration of the service at that moment, stays loaded after the service stops, and a later `start_link/1` without `plugins:` starts with it. See [Services](03-services.md).

## Related Topics

- [Configuration](07-configuration.md) - Learn about initial configuration layers
- [Lifecycle](06-lifecycle.md) - Understanding the full service lifecycle including reconfiguration
- [Plugins](04-plugins.md) - Learn how to implement lifecycle callbacks in plugins
