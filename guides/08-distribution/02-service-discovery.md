# Service Discovery

Once Erlang nodes are connected in a cluster, Malla provides service discovery through the `Malla.Node` module. This allows services to find and call each other regardless of which node they are running on.

## How Discovery Works

### Service Registration
When you define a service with the `global: true` option, the service process joins two process groups of the `:pg` scope `Malla.Services2`: one named after the service ID, and the group `:all`. `:pg` replicates group membership across the connected nodes, so every node can see the service's pid. (`Malla.Node` itself joins the scope too, in a group named `Malla.Node`, to receive updates from the other nodes.)

> #### `global: false` does not hide a service {: .warning}
>
> The process groups are what the periodic check and newly connected nodes use to find services. But every service, global or not, **pushes** its running information to the `Malla.Node` of all connected nodes whenever its running status changes (see below). So a service with `global: false` can still be seen, and called with `Malla.remote/4`, from the nodes that were connected when it last changed status. Do not use `global: false` as an access control; it only means the service is not published in the process groups.

### Health Checks and Updates
`Malla.Node` runs on every node. It learns about services in three ways:

- **Periodic check**: every 10 seconds it asks each member of the `:all` group for its running information.
- **New connections**: when a node connects (`:nodeup`), it checks right away.
- **Pushes**: whenever a service changes its running status, the service sends the new information to the `Malla.Node` of every connected node.

It monitors the service processes, so when one goes down it is removed immediately. Only services whose running status is `:running` are listed: a paused, failed or stopped service is not offered.

### Virtual Modules (Proxy Modules)
When `Malla.Node` detects a global service running on a remote node and **this node has no module with that name**, it generates a local module with the same name. This *virtual module* contains proxy functions for the **callbacks** of the remote service, that is, the functions defined with `defcb` in the service and in its plugins (including those of `Malla.Plugins.Base`, such as `service_is_ready?/0`). Each proxy calls `Malla.remote/3` with the function name and arguments.

This allows you to call a remote service's callbacks as if it were a local module:

```elixir
# On a node that has no module MyRemoteService, while it runs on another node
MyRemoteService.some_callback(arg1, arg2)
```

Things to know:

* **Only callbacks.** A function defined with a plain `def` in the service is not part of the virtual module. Calling it raises `UndefinedFunctionError`. Use `Malla.remote/4` (or `Malla.call`) for those functions: they work for plain functions and callbacks alike.
* **Same-named local module.** If this node has a module with that name (the service's own code is in the application) the virtual module is not created, even when the service is not running here. Calling the module runs the local code; use `Malla.remote/4` to reach the service on other nodes.
* **No options.** A proxy call uses the defaults (the `:remote_timeout` setting, 5 retries when the service is not available). You cannot pass `:timeout` and the others; use `Malla.remote/4`.
* **Discovery takes a moment.** Until the service has been discovered the module does not exist, and calling it raises `UndefinedFunctionError`.
* **Compilation at runtime.** The module is created with `Module.create/3` while the node runs, so the Elixir compiler must be available (it is in a standard Mix release).
* **It follows the service.** If the callbacks of the remote service change, the virtual module is regenerated.

To avoid the second-to-last problem you can pre-create stub modules at application startup, with the `:precompile` setting of the `:malla` application. In your `config/config.exs` or `config/runtime.exs`:

```elixir
config :malla, :precompile, [
  {MyRemoteService, [
    some_callback: 2,
    another_callback: 1
  ]},
  {AnotherRemoteService, [
    do_work: 3
  ]}
]
```

When the `:malla` application starts, it creates a stub module for each entry. These stub modules:
- Contain a function for each callback you list.
- Return `{:error, :malla_service_not_available}` when called before the real service is discovered.
- Are replaced by the real virtual module once the service is discovered on a remote node.

## Using the Discovery API

The `Malla.Node` module provides a public API for querying the cluster about available services.

### Finding Nodes for a Service
The most common use case is to find which nodes are currently running a specific service.

```elixir
# Get a list of nodes running MyService
nodes = Malla.Node.get_nodes(MyService)
# => [:"node1@hostname", :"node2@hostname"]
```
The list of nodes is ordered:
1.  If the service is running on the **local node**, it is always the first element of the list.
2.  The remaining nodes are **shuffled randomly** each time the list is recomputed, that is, each time `Malla.Node` receives a change of service status or does its periodic check (every 10 seconds). The order is not changed on each call.

### Checking Service Availability
You can use `get_nodes/1` to check if a service is available anywhere in the cluster before attempting to call it.

```elixir
case Malla.Node.get_nodes(MyService) do
  [] ->
    # The service is not available on any node
    {:error, :service_unavailable}
  
  [primary_node | _] ->
    # The service is available; primary_node is the first one that a call would try
    {:ok, primary_node}
end
```
Malla also provides a helper to wait for services to become available at startup:
```elixir
# Blocks until all the services are available: :ok, or :timeout after the retries
Malla.Node.wait_for_services([MyService, AnotherService], retries: 10)
```
It checks once per second and returns `:ok` or `:timeout`; the default is 10 retries.

### Getting Detailed Instances
If you need more than just the node name (for example, the service version or pid), use `get_instances/1`.

```elixir
instances = Malla.Node.get_instances(MyService)
# => [
#      {:"node1@hostname", %{id: MyService, vsn: "1.0.0", pid: #PID<...>, running_status: :running, ...}},
#      {:"node2@hostname", %{id: MyService, vsn: "1.1.0", pid: #PID<...>, ...}}
#    ]
```

The map is the service information (`id`, `vsn`, `pid`, `node`, `hash`, `admin_status`, `running_status`, `callbacks`, ...). `vsn` is the string you gave in `use Malla.Service, vsn: ...`; Malla does not use it to choose between instances.

### Listing All Services
To get everything `Malla.Node` knows, use `get_services/0`:

```elixir
%{services_info: info, services_id: ids} = Malla.Node.get_services()
```

`services_info` maps each known service pid to `{service_id, meta}`; `services_id` lists every service ID that has been seen on this node, including those with no instance right now.

## Eventual Consistency

Service discovery is **eventually consistent**. Status changes of a service are pushed to the other nodes, but a node can be unreachable or a message late, and the periodic check (every 10 seconds) is what repairs the differences. So there can be a short window where the information about available services is stale.

## Failover
`Malla.remote/4` calls the nodes of `get_nodes/1` in order. The next node is tried **only** when a node answers `{:error, :malla_service_not_available}`, that is, when the node was reached but the service is not available there (for instance it was just paused). It goes on until one answers or all have been tried; then the result is `{:error, :malla_service_not_available}`.

An exception, a timeout or a lost connection is *not* a reason to try another node. It is returned to the caller as `{:error, {:malla_rpc_error, {error, text}}}` and the call is not repeated elsewhere, unless you pass `excp_retries`, which makes `Malla.remote/4` run the call again. See [Remote Calls](03-remote-calls.md).

## Next Steps

- [Remote Calls](03-remote-calls.md) - Learn how to call functions on distributed services.
- [Cluster Setup](01-cluster-setup.md) - Review how to connect nodes to form a cluster.
