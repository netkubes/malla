# Plugin Development Guide

This guide builds one complete plugin, step by step: an in-memory cache for services. It uses every part of the plugin API: dependencies, callbacks that the plugin offers (with defaults that a service can override), configuration validation and merging, children under a supervisor, reaction to reconfiguration, stop, compile-time injection, readiness and drain. The whole plugin was run and tested against Malla.

Read [Plugins](04-plugins.md), [Callbacks](05-callbacks.md) and [Lifecycle](06-lifecycle.md) first if you have not.

## When to write a plugin

Write a plugin when the behavior is reusable by more than one service, or when you want to be able to add and remove it without touching the service. A callback that only one service needs belongs in that service (a service is a plugin too). A plugin is just a module that does `use Malla.Plugin`; it is not a process. If it needs processes, `plugin_start/2` returns them as children.

## The plan

`MyApp.Plugins.Cache` will:

- store entries in a process (a small GenServer) that the plugin starts and supervises;
- offer two callbacks: `cache_key/1`, which builds the key and has a default that any service can override, and `cache_fetch/2`, which returns the cached value or computes it;
- read its configuration from the `:cache` key (`ttl`, `max_entries`), validate it, and refuse unknown options;
- restart its store when `max_entries` changes, and apply a new `ttl` without a restart;
- report not ready until the store is up, and drain the in-flight computations;
- inject `cache_store/0` in the service module, to find the store.

## The worker

The plugin's child is a normal GenServer. Registering it with a `via` name that includes the service ID and the plugin lets the plugin find it later (`Malla.Service.child_via/3`, `Malla.Service.child_whereis/3`).

```elixir
defmodule MyApp.Plugins.Cache.Store do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def get(store, key), do: GenServer.call(store, {:get, key})
  def put(store, key, value, ttl), do: GenServer.cast(store, {:put, key, value, ttl})

  @impl true
  def init(opts), do: {:ok, %{max: Keyword.fetch!(opts, :max_entries), entries: %{}}}

  @impl true
  def handle_call({:get, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.entries, key) do
      {expires_at, value} when expires_at > now -> {:reply, {:ok, value}, state}
      _ -> {:reply, :miss, %{state | entries: Map.delete(state.entries, key)}}
    end
  end

  @impl true
  def handle_cast({:put, key, value, ttl}, state) do
    expires_at = System.monotonic_time(:millisecond) + ttl
    entries = Map.put(state.entries, key, {expires_at, value})

    entries =
      if map_size(entries) > state.max do
        {oldest, _} = Enum.min_by(entries, fn {_key, {expires_at, _value}} -> expires_at end)
        Map.delete(entries, oldest)
      else
        entries
      end

    {:noreply, %{state | entries: entries}}
  end
end
```

## The plugin

### Declaration and dependencies

```elixir
defmodule MyApp.Plugins.Cache do
  @moduledoc """
  A small in-memory cache for services.

  ## Configuration (key `:cache`)

    * `:ttl` - milliseconds an entry stays valid. Default `60_000`.
    * `:max_entries` - the oldest entry is dropped beyond this number. Default `1000`.

  ## Callbacks it offers

    * `cache_key/1` - turns what you cache into the key. Default: the term itself.
    * `cache_fetch/2` - returns the cached value, or calls the function and caches it.

  ## Injected into the service module

  This plugin uses `c:Malla.Plugin.plugin_module/1` and adds `cache_store/0` to
  the service module: the pid of the store process, or `nil` if it is not running.
  """

  use Malla.Plugin, plugin_deps: [Malla.Plugins.Tracer]
  use Malla.Tracer

  alias MyApp.Plugins.Cache.Store

  @defaults [ttl: 60_000, max_entries: 1000]
  @allowed [:ttl, :max_entries]
```

`plugin_deps: [Malla.Plugins.Tracer]` does two things: it adds the tracer to every service that uses the cache (we use `info/1` below, which needs it), and it places the cache **above** the tracer in the chain. Remember that a plugin is called before the plugins it depends on, and started after them. Dependencies are transitive: a service lists only `MyApp.Plugins.Cache`.

The `@moduledoc` documents what the plugin injects into the service module, as the rule for `plugin_module/1` requires (see below).

### Merging and validating configuration

Configuration goes through two hooks. `plugin_config_merge/3` sees each **update** (at startup, once per layer; and on `reconfigure/2`) and can reject it before it is merged. `plugin_config/2` sees the **merged** configuration and can fill in defaults and validate.

```elixir
  # Called for each update, top-down, before the default deep merge.
  # Return :ok to let the update through, or {:error, reason} to refuse it.
  @impl true
  def plugin_config_merge(_srv_id, _old_config, update) do
    case Keyword.get(update, :cache) do
      nil ->
        :ok

      opts when is_list(opts) ->
        if Keyword.keyword?(opts) do
          case Enum.find(Keyword.keys(opts), &(&1 not in @allowed)) do
            nil -> :ok
            key -> {:error, {:cache_unknown_option, key}}
          end
        else
          {:error, :cache_must_be_a_keyword_list}
        end

      _other ->
        {:error, :cache_must_be_a_keyword_list}
    end
  end

  # Called with the merged configuration, top-down. Fill in the defaults and validate.
  @impl true
  def plugin_config(_srv_id, config) do
    opts = Keyword.merge(@defaults, Keyword.get(config, :cache, []))

    cond do
      not (is_integer(opts[:ttl]) and opts[:ttl] > 0) -> {:error, {:cache_invalid, :ttl}}
      not (is_integer(opts[:max_entries]) and opts[:max_entries] > 0) -> {:error, {:cache_invalid, :max_entries}}
      true -> {:ok, Keyword.put(config, :cache, opts)}
    end
  end
```

Both are ordinary functions (`@impl true`), not `defcb`. An `{:error, reason}` from either one makes `start_link/1` fail, or `reconfigure/2` return `{:error, reason}` and leave the configuration as it was. Note what `plugin_config_merge/3` cannot do: whatever it returns, the update is deep-merged on top afterwards, so it can reject or normalize the *other* keys but not change what the update carries (use `plugin_config/2` for that, as we do for the defaults).

### Starting children

`plugin_start/2` receives the service ID and the final configuration. It returns `{:ok, children: [...]}` and Malla starts a supervisor for the plugin with those children. The options `:strategy` (default `:one_for_one`), `:max_restarts` and `:max_seconds` configure that supervisor.

```elixir
  @impl true
  def plugin_start(srv_id, config) do
    store = Malla.Service.child_via(srv_id, __MODULE__, :store)
    max_entries = get_in(config, [:cache, :max_entries])

    children = [
      %{id: :store, start: {Store, :start_link, [[name: store, max_entries: max_entries]]}}
    ]

    {:ok, children: children, max_restarts: 5, max_seconds: 10}
  end
```

Plugins start bottom-up, after the plugins they depend on. If `plugin_start/2` returns `{:error, reason}`, the service becomes `:failed`, the plugins that had started are stopped, and the service tries again every 5 seconds (see [Lifecycle](06-lifecycle.md)). If the supervisor gives up (here, more than 5 restarts in 10 seconds), the service is marked `:failed` too, and starts the plugin again within 5 seconds. Return `:ok` if the plugin has nothing to supervise.

### Reacting to reconfiguration

`plugin_updated/3` runs after every successful `reconfigure/2` with the old and the new configuration. Return `{:ok, restart: true}` to restart **this plugin** (its supervisor stops and `plugin_start/2` runs again with the new configuration). Do not restart for what you can apply on the fly: here `ttl` is read at each `cache_fetch/2`, so changing it needs nothing.

```elixir
  @impl true
  def plugin_updated(_srv_id, old_config, new_config) do
    if get_in(old_config, [:cache, :max_entries]) != get_in(new_config, [:cache, :max_entries]) do
      {:ok, restart: true}
    else
      :ok
    end
  end
```

### Stopping

`plugin_stop/2` runs when the service stops, when it is set to `:inactive`, and when the plugin is removed at runtime, *before* the plugin's children are stopped. Use it to flush or release things the children do not own.

```elixir
  @impl true
  def plugin_stop(_srv_id, _config) do
    info("cache stopping")
    :ok
  end
```

### Injecting code into the service module

`plugin_module/1` runs while the **service** module is compiled, receives the `Malla.Service` struct and returns quoted code that is spliced into the service module. Use it only when ordinary callbacks cannot do it: here it saves the service from knowing how the store is named. Anything it adds must be documented in the plugin's `@moduledoc`, as above.

```elixir
  @impl true
  def plugin_module(service) do
    quote do
      def cache_store(),
        do: Malla.Service.child_whereis(unquote(service.id), unquote(__MODULE__), :store)
    end
  end
```

`cache_store/0` is a plain function of the service module. It is not a callback, so other nodes' virtual modules for this service do not have it; they can reach it with `Malla.remote/4`.

### Callbacks the plugin offers

Callbacks that the plugin defines with `defcb` are available on every service that uses it. Make the plugin's version the **default** by letting it return a final value: a service, or a plugin that depends on this one, is above it in the chain and can override it, or return `:cont` to fall back to the default.

```elixir
  # The default key is the term itself. A service can override it.
  defcb cache_key(term), do: term

  defcb cache_fetch(term, fun) when is_function(fun, 0) do
    srv_id = Malla.get_service_id!()
    store = Malla.Service.child_whereis(srv_id, __MODULE__, :store)

    if store == nil or Malla.Service.get(srv_id, {__MODULE__, :draining}, false) do
      # No store (or draining): do not cache
      fun.()
    else
      # Calling the service module runs the whole chain, so overrides of cache_key/1 apply
      key = srv_id.cache_key(term)

      case Store.get(store, key) do
        {:ok, value} ->
          value

        :miss ->
          # The service table is a public ETS table named after the service
          counter = {__MODULE__, :in_flight}
          :ets.update_counter(srv_id, counter, 1, {counter, 0})

          try do
            value = fun.()
            Store.put(store, key, value, get_in(srv_id.get_config(), [:cache, :ttl]))
            value
          after
            :ets.update_counter(srv_id, counter, -1)
          end
      end
    end
  end
```

Things to notice:

- Inside a callback, the service ID comes from `Malla.get_service_id!/0`; it was set before the callback ran.
- The plugin keeps its state in the service table with `Malla.Service.get/3` and `put/3`. Use a key that includes your module, `{__MODULE__, :draining}`, so you cannot collide with other plugins. The table belongs to the service process and is gone when it stops.
- A plugin never needs to know which services use it: it asks the service (`srv_id.cache_key(term)`, `srv_id.get_config()`).
- A callback with a `when` guard and no other clause raises `FunctionClauseError` for other arguments. For callbacks that other plugins also implement, add a catch-all that returns `:cont`.

### Readiness and drain

A plugin takes part in the readiness and drain of the service by implementing two callbacks of `Malla.Plugins.Base`. Return `:cont` when this plugin is fine; return `false` otherwise. Do not return `true`: it would end the chain, and the plugins below you would not be asked.

```elixir
  defcb service_is_ready?() do
    srv_id = Malla.get_service_id!()
    if Malla.Service.child_whereis(srv_id, __MODULE__, :store), do: :cont, else: false
  end

  # Called again and again until it returns :cont (see Lifecycle)
  defcb service_drain() do
    srv_id = Malla.get_service_id!()
    Malla.Service.put(srv_id, {__MODULE__, :draining}, true)

    if Malla.Service.get(srv_id, {__MODULE__, :in_flight}, 0) == 0, do: :cont, else: false
  end
end
```

`Malla.Service.is_ready?/1` is `true` only when the service is `:running` and every plugin of the chain answered `:cont`; `Malla.Service.drain/1` is `true` when every plugin did. `GET /is_ready` and `GET /stop` of `Malla.Plugins.Httpd.Lifecycle` use them (see [HTTP Admin Server](11-http-admin.md)).

## Using the plugin

```elixir
defmodule MyApp.Catalog do
  use Malla.Service,
    plugins: [MyApp.Plugins.Cache],
    cache: [ttl: 5_000]

  # Override the default key: cache by product, whatever the locale
  defcb cache_key({:product, id, _locale}), do: {:product, id}
  defcb cache_key(_other), do: :cont

  defcb product(id, locale) do
    cache_fetch({:product, id, locale}, fn -> load_product(id) end)
  end

  defp load_product(id), do: %{id: id, name: "Product #{id}"}
end
```

`cache_fetch/2` is a function of `MyApp.Catalog` as well (every callback of every plugin is), so the service calls it as a local function. The chain of `cache_key/1` is `MyApp.Catalog` first, then the plugin:

```elixir
iex> Malla.Service.get_callbacks(MyApp.Catalog, :cache_key)
[{{:cache_key, 1}, [{MyApp.Catalog, :cache_key_malla_service}, {MyApp.Plugins.Cache, :cache_key}]}]

iex> {:ok, _} = MyApp.Catalog.start_link()
iex> MyApp.Catalog.product(1, "en")
%{id: 1, name: "Product 1"}
iex> MyApp.Catalog.cache_store()
#PID<0.201.0>
iex> MyApp.Catalog.reconfigure(cache: [ttl: 10_000])      # applied on the fly
:ok
iex> MyApp.Catalog.reconfigure(cache: [max_entries: 10])  # plugin_updated/3 restarts the store
:ok
iex> MyApp.Catalog.reconfigure(cache: [bogus: 1])
{:error, {:cache_unknown_option, :bogus}}
```

## Checklist for a plugin

- `plugin_deps` lists the plugins you call (a tracer, `Malla.Plugins.Request`, ...). Remember the plugin is called *before* what it depends on.
- Lifecycle hooks are normal functions with `@impl true`; only the callbacks that take part in chains are `defcb`.
- Every `defcb` that other plugins might also implement ends with a clause that returns `:cont`, or is the bottom of a chain that returns a real value. A chain that ends in `:cont` returns the raw `:cont` to the caller.
- A `defcb` with a default argument registers only the highest arity; write each arity you want.
- Configuration under one key named after the plugin; use keyword lists for what operators will update partially (maps are replaced, not merged).
- Validation in `plugin_config/2` (and `plugin_config_merge/3` to refuse an update early); defaults filled in `plugin_config/2`.
- State you need to share goes in the service table with a key that includes your module, or in children you register with `Malla.Service.child_via/3`.
- `plugin_stop/2` releases what the children do not own; children are stopped by Malla right after.
- If you use `plugin_module/1`, document what you inject.
- Test it with a minimal service: see [Testing](12-testing.md).

## Next Steps

- [Testing](12-testing.md) - test the plugin with a minimal service.
- [Reconfiguration](07a-reconfiguration.md) - details of the merge and update phases.
- [Troubleshooting](14-troubleshooting.md) - plugin order surprises and how to inspect them.
