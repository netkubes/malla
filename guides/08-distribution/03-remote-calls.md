# Remote Calls

Malla provides several ways to call functions on services running on other nodes in the cluster. These mechanisms handle service discovery, routing, and failover automatically.

For structured inter-service communication with distributed tracing, standardized responses, and plugin interception, see the [Request Handling](04-request-handling.md) guide.

## Transparent Calls (Virtual Modules)

The simplest way to call a remote service is to call it as if it were a local module.

```elixir
# This looks like a local call, but Malla can route it to a remote node.
MyRemoteService.my_function(arg1, arg2)
```

This works because of Malla's "virtual module" feature. If `MyRemoteService` is registered as a global service but is not running on the local node, Malla dynamically creates a proxy module that forwards the call to a node where the service *is* running.

For more details on how virtual modules work, including how to pre-compile stub modules to handle services that aren't yet connected, see the [Virtual Modules (Proxy Modules)](02-service-discovery.md#virtual-modules-proxy-modules) section in the Service Discovery guide.

## Malla.remote

For full control over remote calls, including custom timeouts and retry behavior, you can use `Malla.remote/4`. This function is designed to invoke a `defcb` callback (or any public function) on a remote service.

```elixir
Malla.remote(
  MyRemoteService,      # The service to call
  :my_callback,         # The function to call
  [arg1, arg2],         # The arguments
  timeout: 10_000       # Options, including timeout
)
```

### How Malla.remote Works

1.  It uses `Malla.Node.get_nodes(MyRemoteService)` to find available nodes.
2.  It attempts to call the function on the first node in the list.
3.  Failover: If the call fails with a `{:error, :malla_service_not_available}` message, it automatically retries the call on the next available node.
4.  It continues until the call succeeds or it runs out of nodes to try.

### Additional Options

You can also configure retry behavior when a service is not available:

```elixir
Malla.remote(
  MyRemoteService,
  :my_callback,
  [arg1, arg2],
  timeout: 10_000,
  sna_retries: 5,              # Retry up to 5 times if service not available
  retries_sleep_msec: 1000     # Wait 1 second between retries
)
```

## Malla.call Macro

For a more natural syntax when making remote calls, you can use the `Malla.call/2` macro. It provides syntactic sugar that makes remote calls look like regular function calls.

```elixir
# Instead of writing:
Malla.remote(MyRemoteService, :my_function, [arg1, arg2])

# You can write:
import Malla, only: [call: 1, call: 2]
call MyRemoteService.my_function(arg1, arg2)
```

The macro automatically extracts the module name, function name, and arguments from the expression and translates it into a `Malla.remote/3` or `Malla.remote/4` call.

**When to use it**: This is ideal when you want the readability of function call syntax while still having explicit control over remote invocation (unlike transparent virtual module calls).

### Basic Usage

```elixir
# Call a remote service with clear syntax
result = Malla.call(UserService.get_user_by_id(123))

case result do
  {:ok, user} -> 
    IO.inspect(user)
  {:error, :malla_service_not_available} -> 
    IO.puts("Service not available")
end
```

### Using Options

You can pass options to control timeout, retries, and other behavior, just like with `Malla.remote/4`:

```elixir
# With custom timeout
call MyRemoteService.heavy_computation(data), timeout: 30_000

# With retry configuration
call MyRemoteService.unreliable_function(args),
  timeout: 10_000,
  sna_retries: 10,              # Retry up to 10 times if service not available
  retries_sleep_msec: 2000      # Wait 2 seconds between retries

# With exception retries (use carefully!)
call MyRemoteService.risky_operation(data),
  excp_retries: 3,
  retries_sleep_msec: 1000
```

### Available Options

All options supported by `Malla.remote/4` are available:

- `:timeout` - Request timeout in milliseconds (default: 15000)
- `:sna_retries` - Number of retries when service is not available (default: 5)
- `:excp_retries` - Number of retries on exceptions (default: 0)
- `:retries_sleep_msec` - Sleep time between retries in milliseconds (default: 1000)

**Important**: Be careful with `:excp_retries` as the request may have been partially processed on the remote side before the exception occurred.


### Calling All Nodes

You can also broadcast a call to *all* nodes running a service using `call_cb_all/4`.

```elixir
# Returns a list of results from each node
results = Malla.Node.call_cb_all(MyWorkerService, :perform_work, [work_item])
```
