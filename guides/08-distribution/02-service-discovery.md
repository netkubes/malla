# Service Discovery

Once Erlang nodes are connected in a cluster, Malla provides automatic service discovery through the `Malla.Node` module. This allows services to find and communicate with each other regardless of which node they are running on.

## How Discovery Works

### Service Registration
When you define a service with the `global: true` option, it automatically registers itself in a cluster-wide process group (specifically, the `:pg` group named `Malla.Services2`). This makes the service's process ID (pid) visible to all other nodes in the cluster.

### Health Checks
The `Malla.Node` process on each node periodically (every 10 seconds by default) performs health checks on all registered global services. It tracks which services are running on which nodes, along with their versions and other metadata. It also uses process monitoring to detect when a service or an entire node goes down.

### Virtual Modules (Proxy Modules)
A key feature of Malla is its use of "virtual" or "proxy" modules. When `Malla.Node` detects a global service running on a remote node that is *not* running on the local node, it can dynamically create a local module with the same name as the remote service. This module contains proxy functions for all the callbacks available on the remote service.

This allows you to call a remote service as if it were a local module, without writing any explicit RPC code.

```elixir
# This looks like a local call, but Malla may route it to a remote node
# if MyRemoteService is not running locally but is available elsewhere in the cluster.
MyRemoteService.some_function(arg1, arg2)
```

This approach has however some limitations:
* You cannot provide options like `:timeout`
* If the remote service is not yet connected, the call will fail since the module does not exist yet

To solve the second problem where calls fail because the module doesn't exist yet you can pre-create stub modules at application startup. This is done by configuring the `:precompile` option in your application's config.

In your `config/config.exs` or `config/runtime.exs`:

```elixir
config :malla, :precompile, [
  {MyRemoteService, [
    some_function: 2,
    another_callback: 1
  ]},
  {AnotherRemoteService, [
    do_work: 3
  ]}
]
```

When your application starts, `Malla.Node.precompile_stubs/0` is automatically called during application's start. This function reads the `:precompile` config and creates stub modules for each configured service.

These stub modules:
- Contain proxy functions for all specified callbacks
- Return `{:error, :malla_service_not_available}` when called before the real service is discovered
- Are automatically replaced by the real virtual module once the service is discovered on a remote node


## Using the Discovery API

The `Malla.Node` module provides a public API for querying the cluster about available services.

### Finding Nodes for a Service
The most common use case is to find which nodes are currently running a specific service.

```elixir
# Get a list of nodes running MyService
nodes = Malla.Node.get_nodes(MyService)
# => [:"node1@hostname", :"node2@hostname"]
```
The list of nodes is ordered to provide simple load balancing and locality:
1.  If the service is running on the **local node**, it will always be the first element in the list.
2.  The remaining nodes are **randomly shuffled** on each health check cycle to distribute load.

### Checking Service Availability
You can use `get_nodes/1` to check if a service is available anywhere in the cluster before attempting to call it.

```elixir
case Malla.Node.get_nodes(MyService) do
  [] ->
    # The service is not available on any node
    {:error, :service_unavailable}
  
  [primary_node | _] ->
    # The service is available, with primary_node being the best candidate for a call
    {:ok, primary_node}
end
```
Malla also provides a helper to wait for services to become available at startup:
```elixir
# This will block until all services are available, or timeout.
Malla.Node.wait_for_services([MyService, AnotherService], retries: 10)
```

### Getting Detailed Instances
If you need more than just the node name (e.g., the service version or pid), you can use `get_instances/1`.

```elixir
instances = Malla.Node.get_instances(MyService)
# => [
#      {:"node1@hostname", %{vsn: "1.0.0", pid: #PID<...>, ...}},
#      {:"node2@hostname", %{vsn: "1.1.0", pid: #PID<...>, ...}}
#    ]
```

### Listing All Services
To get a list of all services discovered across the entire cluster, use `get_services/0`.

```elixir
Malla.Node.get_services()
```

## Eventual Consistency

Service discovery in Malla is **eventually consistent**. Because health checks run periodically (every 10 seconds), there can be a brief window where the information about available services is stale. For example, if a service crashes, it might take up to 10 seconds for other nodes to register that it is gone.

## Failover
Malla's remote call functions (like `Malla.remote/4`) use the ordered list from `get_nodes/1` to provide automatic failover. If a call to the first node in the list fails because the service is not available, it will automatically retry the call on the next node in the list, continuing until it succeeds or has exhausted all available nodes.

## Next Steps

- [Remote Calls](03-remote-calls.md) - Learn how to call functions on distributed services.
- [Cluster Setup](01-cluster-setup.md) - Review how to connect nodes to form a cluster.
