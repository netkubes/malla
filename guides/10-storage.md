# Storage and State Management

Malla provides several mechanisms for managing state, from ephemeral service-specific data to node-wide configuration and process registration.

## Service Storage (ETS)

Each running service has its own ETS table. It is a public, named table whose name is the **service module** (`MyService`). It is created by the service process when it starts, which makes that process its owner, and it is lost when that process stops: all its data goes with it. It is not persistent and it is not shared between nodes.

This is ideal for use cases like:
-   Caching processed results.
-   Tracking request counts or other metrics.
-   Storing temporary state shared by the callbacks of a service and of its plugins.

The `Malla.Service` module provides a simple API for this key-value store.

```elixir
# Store data for a specific service
:ok = Malla.Service.put(MyService, :my_key, "some_value")

# Retrieve the data (the third argument is the default, nil if omitted)
value = Malla.Service.get(MyService, :my_key, "default")
# => "some_value"

# Insert only if the key does not exist yet
Malla.Service.put_new(MyService, :my_key, "other")
# => false  (and the value is unchanged); true if it was inserted

# Delete the data
:ok = Malla.Service.del(MyService, :my_key)
```

The functions are thin wrappers over `:ets`, called in the process of the caller. If the service is not running there is no table, and `get/3`, `put/3`, `put_new/3` and `del/2` raise `ArgumentError`. The table is *public*: any process on the node can read and write it, so use keys that cannot collide with those of a plugin (for example `{__MODULE__, :key}`).

Plugins use the service table too: the service ID is the first argument (get it from `Malla.get_service_id!/0` inside a callback, or from the first argument of `plugin_start/2`).

```elixir
defcb service_is_ready?() do
  srv_id = Malla.get_service_id!()

  if Malla.Service.get(srv_id, {__MODULE__, :pool_ready}, false), do: :cont, else: false
end
```

## Process Registry

For registering and looking up named processes, Malla provides the `Malla.Registry` module. It offers two types of registries: one for unique names and one that allows multiple processes to be registered under the same key. Both are node-wide (they are not scoped to a service); the keys are any term.

### Unique Process Registration
This is useful for singleton processes, like a worker that should only have one instance running. You can use `Malla.Registry.via/1` to name a GenServer.

```elixir
# Register a GenServer with a unique name
{:ok, pid} = GenServer.start_link(MyWorker, [], name: Malla.Registry.via("my_unique_worker"))

# Look up the process later
pid = Malla.Registry.whereis("my_unique_worker")
```

If you try to start another process under the same name, `GenServer.start_link/3` returns `{:error, {:already_started, pid}}`, as with any registered name.

A process can also register itself with `Malla.Registry.register/2`; this one answers `{:error, {:already_registered, pid}}` when the key is taken:

```elixir
{:ok, _} = Malla.Registry.register(:leader, %{since: DateTime.utc_now()})
Malla.Registry.lookup(:leader)
# => {#PID<0.150.0>, %{since: ~U[...]}}
```

### Naming the Children of a Plugin

`Malla.Service.child_via/3` builds a `via` tuple that includes the service ID and the plugin, so two services (or two plugins) can use the same local name without colliding. `Malla.Service.child_whereis/3` finds the process again:

```elixir
defmodule MyPlugin do
  use Malla.Plugin

  @impl true
  def plugin_start(srv_id, _config) do
    name = Malla.Service.child_via(srv_id, __MODULE__, :pool)

    {:ok, children: [%{id: :pool, start: {Agent, :start_link, [fn -> %{} end, [name: name]]}}]}
  end
end

Malla.Service.child_whereis(MyService, MyPlugin, :pool)
# => #PID<0.200.0>
```

The supervisor of each plugin is registered too; `Malla.Service.get_plugin_sup/2` returns its pid (or `nil`).

### Duplicate Process Registration (Store)
This allows you to register multiple processes under the same key, which is useful for managing pools of workers.

```elixir
defmodule MyWorker do
  use GenServer

  def start_link(id), do: GenServer.start_link(__MODULE__, id)

  # A worker registers itself on start
  def init(id) do
    Malla.Registry.store(:my_worker_pool, %{worker_id: id})
    {:ok, %{id: id}}
  end
end

# Find all registered workers
workers = Malla.Registry.values(:my_worker_pool)
# => [{#PID<...>, %{worker_id: 1}}, {#PID<...>, %{worker_id: 2}}]

Malla.Registry.count(:my_worker_pool)
# => 2
```

`Malla.Registry.values/3` and `count/3` also accept a match pattern and guards, and `Malla.Registry.unstore/1` removes the registration of the current process. Registrations disappear when the process ends.

## Node-wide Store

For values that need to be accessed by multiple services or other parts of your application on the same node, use `Malla.Config`. It is an ETS-based store owned by the `:malla` application: it survives service restarts but is local to each node (it is not distributed) and is lost when the node stops. Keys are grouped by a *domain*: any term, typically your application name.

```elixir
# Store and retrieve a value
Malla.Config.put(:my_app, :limit, 100)
Malla.Config.get(:my_app, :limit, 0)
# => 100

# Atomic counter: it must have an initial integer value
Malla.Config.put(:my_app, :requests, 0)
Malla.Config.increment(:my_app, :requests, 1)
# => 1

# Read-modify-write, serialized through the store's process
Malla.Config.update(:my_app, :limit, fn old -> old * 2 end)
# => :ok

# Add a value to a list, only if it is not there yet (serialized)
Malla.Config.add(:my_app, :tags, "blue")
# => :ok

Malla.Config.del(:my_app, :limit)
```

Details:
- `increment/3` raises `ArgumentError` if the key has no integer value yet.
- `update/3` answers `{:error, exception}` if your function raises, and leaves the value as it was.
- `add/3` answers `{:error, :invalid_value}` if the key holds something that is not a list. A new value goes to the head of the list.

The storage mechanisms described above are **not persistent** and lose their data if the node is restarted. For durable state, use an external persistence strategy.
