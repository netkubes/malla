# Remote Calls

Malla provides several ways to call functions on services running on other nodes of the cluster. They use service discovery to find a node that runs the service, so you do not have to know where it is.

For structured inter-service communication with trace propagation, standardized responses, and interception on the called side, see the [Request Handling](04-request-handling.md) guide.

## Transparent Calls (Virtual Modules)

On a node that does not have the module of a service, you can call the **callbacks** of a remote service as if it were a local module.

```elixir
# On a node without a MyRemoteService module of its own:
MyRemoteService.my_callback(arg1, arg2)
```

This works because of Malla's "virtual module" feature. If `MyRemoteService` is a service that `Malla.Node` has discovered running on another node, and this node has no module with that name, Malla generates a module with proxy functions that forward the call to a node where the service is running.

Limitations:

- The virtual module has proxies for functions defined with `defcb` only. A function defined with plain `def` does not exist in it, and calling it raises `UndefinedFunctionError`. Use `Malla.remote/4` for those functions.
- A proxy cannot take options: it uses the default timeout and the default retries.
- If this node does have a module with that name (the service's code is in your application), the call is executed locally, even if the service is not running here. To reach the service on another node, use `Malla.remote/4`.

For more details, including how to pre-create stub modules for services that are not yet connected, see the [Virtual Modules (Proxy Modules)](02-service-discovery.md#virtual-modules-proxy-modules) section in the Service Discovery guide.

## Malla.remote

For full control over remote calls, including timeouts and retry behavior, use `Malla.remote/4`. It invokes a `defcb` callback **or any public function** of the service module, on a node that runs the service. The service may also be running on the local node, which is always tried first.

```elixir
Malla.remote(
  MyRemoteService,      # The service to call
  :my_callback,         # The function to call
  [arg1, arg2],         # The arguments
  timeout: 10_000       # Options, including timeout
)
```

### How Malla.remote Works

1.  It uses `Malla.Node.get_nodes(MyRemoteService)` to find the nodes that run the service.
2.  It calls the function on the first node of the list, with `:erpc`. On the remote node the call enters through the `service_cb_in/3` callback of the service, with the service ID set in the process dictionary and the group leader set to `:user`, so that IO does not go back to the caller.
3.  If that node answers `{:error, :malla_service_not_available}` the call is made on the next node of the list, and so on. If none is left, the result is `{:error, :malla_service_not_available}`.
4.  If the result is `{:error, :malla_service_not_available}` and `sna_retries` is greater than zero, `Malla.remote/4` sleeps `retries_sleep_msec` and starts again from step 1 (the list of nodes is computed again), up to `sna_retries` times. The default is 5 retries one second apart, so a call to a service that is nowhere takes about 5 seconds to fail. Pass `sna_retries: 0` to fail at once.

Only `{:error, :malla_service_not_available}` makes Malla try another node. An exception on the remote node, a timeout or a lost connection is **not** retried on another node; see "Errors" below.

### Options

- `:timeout` - Timeout of each call in milliseconds. Default: the `:remote_timeout` setting of the `:malla` application, read on every call, or 15000 when not set (`config :malla, remote_timeout: 20_000`). With `timeout: 0` the call is a cast: it does not wait, and `Malla.remote/4` returns `:ok`.
- `:sna_retries` - Number of retries when the service is not available. Default: 5.
- `:excp_retries` - Number of times the call is run again after an exception, a timeout or a lost connection. Default: 0.
- `:retries_sleep_msec` - Sleep between retries of either kind, in milliseconds. Default: 1000.

```elixir
Malla.remote(
  MyRemoteService,
  :my_callback,
  [arg1, arg2],
  timeout: 10_000,
  sna_retries: 5,              # Retry up to 5 times if the service is not available
  retries_sleep_msec: 1000     # Wait 1 second between retries
)
```

**Important**: be careful with `:excp_retries`. The request may have been partially processed on the remote side before the exception (or the timeout) occurred, and a retry runs it again.

### Errors

| Result | Meaning |
| :--- | :--- |
| `{:error, :malla_service_not_available}` | No node runs the service, or every node answered that it is not available (after the `sna_retries`). |
| `{:error, {:malla_rpc_error, {error, text}}}` | The call raised an exception or exited on the remote node, it timed out (`error` is then `%ErlangError{original: {:erpc, :timeout}}`) or the connection was lost, and `excp_retries` are spent. `text` is a formatted stacktrace, meant for your logs. |
| anything else | The value returned by the function, unchanged. |

`Malla.remote/4` does not interpret what the function returns: `{:error, reason}` from your own function comes back as is. With `timeout: 0` the result is always `:ok`.

The text of a remote exception is never put in a public `Malla.Status`: `Malla.Status.public/2` hands `{:malla_rpc_error, ...}` to `status_public/1`, which logs it under a reference and answers `"internal_error"` (see [Status Handling](../09-observability/02-status-handling.md)).

## Malla.call Macro

For a more natural syntax, use the `Malla.call/2` macro. It makes remote calls look like regular function calls. You need `require Malla` (or `import Malla, only: [call: 1, call: 2]`) first.

```elixir
require Malla

# Instead of writing:
Malla.remote(MyRemoteService, :my_function, [arg1, arg2])

# You can write:
Malla.call MyRemoteService.my_function(arg1, arg2)
```

The macro takes the module, function name and arguments from the expression and turns it into a `Malla.remote/3` or `Malla.remote/4` call. The module part is an ordinary expression: an alias, a variable or `__MODULE__` all work.

```elixir
require Malla

case Malla.call(UserService.get_user_by_id(123)) do
  {:ok, user} ->
    IO.inspect(user)

  {:error, :malla_service_not_available} ->
    IO.puts("Service not available")
end
```

### Using Options

You can pass the same options as to `Malla.remote/4`:

```elixir
# With custom timeout
Malla.call MyRemoteService.heavy_computation(data), timeout: 30_000

# With retry configuration
Malla.call MyRemoteService.unreliable_function(args),
  timeout: 10_000,
  sna_retries: 10,
  retries_sleep_msec: 2000

# With exception retries (use carefully!)
Malla.call MyRemoteService.risky_operation(data),
  excp_retries: 3,
  retries_sleep_msec: 1000
```

## Calling All Nodes

You can also send a call to *all* the nodes running a service with `Malla.Node.call_cb_all/4`. It returns one result per node, in a list; nothing is retried and nothing fails over.

```elixir
# Returns a list of results, one from each node
results = Malla.Node.call_cb_all(MyWorkerService, :perform_work, [work_item])

# Fire and forget: one cast per node, nothing waits for the answers
Malla.Node.call_cb_all(MyWorkerService, :invalidate_cache, [key], timeout: 0)
```

## Lower-level Functions in `Malla.Node`

`Malla.remote/4` is built on `Malla.Node.call_cb/4`, which is built on `Malla.Node.call/4`:

- `Malla.Node.call_cb/4` calls the service's callback entry point on the first node that answers. It does not retry when the service is not available anywhere, and a failure comes back as `{:error, {:malla_rpc, {error, text}}}` (note `:malla_rpc`; `Malla.remote/4` renames it to `:malla_rpc_error`). Its default timeout is 30 seconds when you do not pass `:timeout`.
- `Malla.Node.call/4` calls any module and function on the nodes that run a service. You give it the service in the `:service_id` option (or in the process dictionary), or a list of nodes with `:nodes`.

Prefer `Malla.remote/4` unless you need one of these.
