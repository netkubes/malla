# Storage and State Management

Malla provides several mechanisms for managing state, from ephemeral service-specific data to node-wide configuration and process registration.

## Service Storage (ETS)

Each Malla service instance is automatically provided with its own dedicated ETS table for storing runtime data. This storage is ephemeral: it is created when the service starts and is destroyed when the service stops.

This is ideal for use cases like:
-   Caching processed results.
-   Tracking request counts or other metrics.
-   Storing temporary session data or workflow state.

The `Malla.Service` module provides a simple API for this key-value store.

```elixir
# Store data for a specific service
Malla.Service.put(MyService, :my_key, "some_value")

# Retrieve the data
value = Malla.Service.get(MyService, :my_key, "default")
# => "some_value"

# Delete the data
Malla.Service.del(MyService, :my_key)
```

## Process Registry

For registering and looking up named processes, Malla provides the `Malla.Registry` module. It offers two types of registries: one for unique names and one that allows multiple processes to be registered under the same key.

### Unique Process Registration
This is useful for singleton processes, like a worker that should only have one instance running. You can use `Malla.Registry.via/1` to easily name a GenServer.

```elixir
# Register a GenServer with a unique name
GenServer.start_link(MyWorker, [], name: Malla.Registry.via("my_unique_worker"))

# Look up the process later
pid = Malla.Registry.whereis("my_unique_worker")
```
If you try to register another process with the same name, you will get an `{:error, {:already_registered, pid}}` tuple.

### Duplicate Process Registration (Store)
This allows you to register multiple processes under the same key, which is useful for managing pools of workers.

```elixir
# A worker registers itself on start
def MyWorker.init(id) do
  Malla.Registry.store(:my_worker_pool, %{worker_id: id})
  {:ok, %{id: id}}
end

# Find all registered workers
workers = Malla.Registry.values(:my_worker_pool)
# => [{#PID<...>, %{worker_id: 1}}, {#PID<...>, %{worker_id: 2}}]
```

## Global Configuration Store

For node-wide configuration that needs to be accessed by multiple services or other parts of your application, you can use `Malla.Config`. This is an ETS-based store that survives service restarts but is local to each node (i.e., it is not distributed).

```elixir
# Store a global setting
Malla.Config.put(:my_app, :api_key, "secret_key")

# Retrieve the setting from anywhere on the same node
key = Malla.Config.get(:my_app, :api_key)
```

The storage mechanisms mentioned above are **not persistent** and will lose their data if the node is restarted. For durable state, you must use an external persistence strategy.

