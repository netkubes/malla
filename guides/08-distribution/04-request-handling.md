# Request Handling

Malla's _request handling system_ is an optional protocol for inter-service communication. It builds on `Malla.remote/4` and adds a pair of spans that continue a trace across nodes, normalization of responses and errors into `Malla.Status`, telemetry, and a callback, `malla_request/3`, that plugins of the **called** service can use to intercept requests.

## Why Request Handling?

While Malla provides basic remote calls via `Malla.remote/4`, the request system adds:

- **Standardized responses**: the answers of the called function are normalized into a small set of shapes, and errors into `t:Malla.Status.t/0`.
- **Trace propagation**: the `request-out` span of the caller hands its context to the `request-in` span of the called service. (`Malla.remote/4` does not do this.) Real traces need a tracer plugin; see [Tracing](../09-observability/01-tracing.md).
- **Interception on the called side**: cross-cutting concerns such as authentication, rate limiting and validation, as plugins of the service that receives the request.
- **Telemetry**: `[:malla, :request, :out]` and `[:malla, :request, :in]` events.
- **Error normalization**: a consistent error shape that does not leak internals (see "Errors" below).

The retry options are those of `Malla.remote/4` (`sna_retries`, `excp_retries`, `retries_sleep_msec`); there is nothing else on top of them.

## What you need

- **The called service** needs `Malla.Plugins.Request`. The caller sends the request by calling the `malla_request/3` callback of the target; a service without the plugin has no such callback, and the call fails with an internal error.
- **The calling service** needs `Malla.Tracer` and `Malla.Status` available, because `Malla.Request` calls `Malla.Tracer.span/3` and `Malla.Status.public/2` with its service ID. `Malla.Plugins.Request` depends on `Malla.Plugins.Tracer` and `Malla.Plugins.Status`, so listing it in the caller pulls both in.
- **A service ID in the calling process.** `request/4` (and `req`) open a span for the calling service, so the process needs a service ID, or you must pass the `service_id:` option. Without one they raise `Malla.ServiceIdMissing`. Inside a `defcb` of the service the ID is already set. In a plain function, or in a process you spawned, call `Malla.put_service_id(MyService)` first or pass `service_id: MyService`.

## Basic Usage

### Simple Request/Response

```elixir
# A service that provides user data
defmodule MyApp.UserService do
  use Malla.Service, global: true, plugins: [Malla.Plugins.Request]

  def get_user(1), do: {:ok, %{id: 1, name: "Ann"}}
  def get_user(_id), do: {:error, :not_found}

  def list_users(), do: {:ok, [%{id: 1, name: "Ann"}]}
end

# Call it from another service
defmodule MyApp.APIService do
  use Malla.Service, plugins: [Malla.Plugins.Request]
  use Malla.Request   # imports the req macro

  # A callback: the service ID is set in the process
  defcb fetch_user(user_id) do
    case req MyApp.UserService.get_user(user_id) do
      {:ok, user} ->
        {:ok, user}

      {:error, %Malla.Status{status: "not_found"}} ->
        {:error, :user_not_found}
    end
  end
end
```

The functions that answer requests (`get_user/1`) are ordinary functions of the service module; they do not have to be callbacks. Anything the service module exports can be requested.

`req` finds a node running `MyApp.UserService`, with the same discovery as `Malla.remote/4`, and returns what `Malla.Request.request/4` returns.

> #### `req` takes the module name literally {: .warning}
>
> The `req` macro builds the service ID from the aliases as they are written, without expanding `alias` declarations. After `alias MyApp.UserService`, `req UserService.get_user(1)` asks for a service named `UserService` (not `MyApp.UserService`), which does not exist, and you get a `service_not_available` status. Write the full module name in `req`, or use the function form below, which takes the module as a normal argument. The expression must also be a literal module name: `req mod.get_user(1)` with a variable does not match.

### Function Syntax

```elixir
# Equivalent to: req MyApp.UserService.get_user(123)
Malla.Request.request(MyApp.UserService, :get_user, [123])

# With options
Malla.Request.request(MyApp.UserService, :get_user, [123], timeout: 10_000)
```

`Malla.Request.request!/4` is the same but it raises `Malla.Request.ReqError` when the service is not available (`type: :service_not_available`) or the answer is an internal error (`type: :internal_error`). Other errors (a `not_found`, for example) are returned, not raised.

## Response Protocol

### What the called function returns

The function that handles the request (running on the called service) must return one of:

| Return value | What the caller gets |
| :--- | :--- |
| `:ok` | `{:ok, %{}}` |
| `:created` | `{:created, %{}}` |
| `{:ok, data}` / `{:created, data}`, `data` a map or a list | `{:ok, data}` / `{:created, data}` |
| `{:error, term}` | `{:error, %Malla.Status{}}`, built from `term` (see below) |
| `{:status, term}` | `{:status, %Malla.Status{}}`, built from `term` |
| anything else (including `{:ok, "a string"}`) | `{:error, %Malla.Status{status: "internal_error", info: "Invalid request handler response"}}` |

Note that a bare `:ok` reaches the caller as `{:ok, %{}}`, so `:ok = req Service.fun()` never matches; match `{:ok, _}`.

```elixir
defmodule MyApp.ProductService do
  use Malla.Service, global: true, plugins: [Malla.Plugins.Request]

  # Success with no data
  def health_check(), do: :ok

  # Success with data (a map or a list)
  def get_product(id), do: {:ok, %{id: id, stock: 7}}

  # Resource created with data
  def create_product(params), do: {:created, %{id: 99, name: params.name}}

  # Errors
  def check_stock(_id, quantity) when quantity > 7, do: {:error, {:out_of_stock, 7}}
  def check_stock(_id, _quantity), do: :ok

  # Teach the status system about your own errors (see "Errors")
  defcb status({:out_of_stock, available}),
    do: [info: "Out of stock", code: 409, data: [available: available]]

  defcb status(_), do: :cont
end
```

### What the caller gets

`request/4` returns `{tag, data}`, always a two-element tuple:

| Result | When |
| :--- | :--- |
| `{:ok, map_or_list}` / `{:created, map_or_list}` | success; `%{}` when the handler returned a bare `:ok`/`:created` |
| `{:error, %Malla.Status{}}` | the handler returned `{:error, term}`, or something went wrong (see "Errors") |
| `{:status, %Malla.Status{}}` | the handler returned `{:status, term}` |

An error that is not a `%Malla.Status{}` when it reaches the caller (for example `{:error, :malla_service_not_available}` from the transport, or the bare reason an interceptor returned) is converted by the caller's own `Malla.Status.public/2`.

## How Requests Work

When you call `req MyApp.UserService.get_user(123)`:

1. **Client side**:
   - Opens a `request-out` span (in the calling service, via `Malla.Tracer.span/3`) and logs the request.
   - Gets the context of the current span (`Malla.Tracer.get_base/0`) to send it along.
   - Calls `malla_request(:get_user, [123], opts)` on the target with `Malla.remote/4`, so with its options (`timeout`, retries), or locally if you passed `direct: true`.

2. **Server side** (on the called service): the `malla_request/3` callback chain runs. Plugins of that service can intercept it here. The default implementation, from `Malla.Plugins.Request`:
   - Answers `{:error, :malla_service_not_available}` if the service is not `:running` (a paused service, for example).
   - Opens a `request-in` span with the context received from the client as its base.
   - Calls your function: `MyApp.UserService.get_user(123)`.
   - Normalizes the answer as in the table above, with `Malla.Status.public/1` of the called service for errors.
   - Emits `[:malla, :request, :in]` and returns `{tag, data}`.

3. **Client side** (the answer): the result is normalized as described above, `[:malla, :request, :out]` is emitted, and `{tag, data}` is returned.

## Request Options

`req` and `request/4` take the options of `Malla.remote/4`, plus `:direct` and `:service_id`. Everything else is passed to the called service and visible to its plugins:

```elixir
# Timeout of the call (default: config :malla, :remote_timeout, 15 000 ms)
req MyApp.UserService.get_user(123), timeout: 5_000

# Do not use RPC: call malla_request/3 of the target module in this node
req MyApp.UserService.get_user(123), direct: true

# The service ID to use (the calling service), when the process has none
Malla.Request.request(MyApp.UserService, :get_user, [123], service_id: MyApp.APIService)

# Retries of Malla.remote/4
req MyApp.UserService.heavy_operation(data),
  timeout: 30_000,
  sna_retries: 2,            # when the service is not available (default 5)
  retries_sleep_msec: 500    # between retries (default 1000)
  # excp_retries: 1          # re-run after an exception or timeout (default 0). Be careful.

# Custom options for the plugins of the called service
req MyApp.UserService.create_user(params),
  auth_token: "abc123",
  request_id: "r-1"
```

Custom options travel to the other node, so they must be plain terms. The called service receives all of them in the `opts` argument of `malla_request/3`, together with the trace context (under `:base_span`, and `:trace_base` for older plugins).

## Distributed Tracing

The `request-out` and `request-in` spans are linked: the caller gets the base context with `Malla.Tracer.get_base/0` and the called service opens its span with `base: <that context>` in the span options. What that context contains, and what is done with it, is up to the tracer plugin you use. With the default `Malla.Plugins.Tracer` the context is `nil`: spans only emit telemetry counters.

```elixir
defmodule MyApp.OrderService do
  use Malla.Service, plugins: [Malla.Plugins.Request]
  use Malla.Request
  use Malla.Tracer

  defcb create_order(user_id, items) do
    span [:order_service, :create_order] do
      info("Creating order", user_id: user_id, item_count: length(items))

      # Each req call is a request-out span, child of the span above
      {:ok, _user} = req MyApp.UserService.get_user(user_id)

      Enum.each(items, fn item ->
        {:ok, _} = req MyApp.ProductService.check_stock(item.product_id, item.quantity)
      end)

      {:created, %{user_id: user_id}}
    end
  end
end
```

With a tracer plugin that understands the context, this produces a trace like:

```
order_service:create_order (OrderService, node1)
  ├─ request-out → request-in (UserService, node2)
  ├─ request-out → request-in (ProductService, node3)
  └─ request-out → request-in (ProductService, node3)
```

Only `Malla.Request` propagates the context. A plain `Malla.remote/4` or a call through a virtual module does not.

See the [Tracing guide](../09-observability/01-tracing.md) for more details.

## Plugin-Based Interception

Plugins implement `c:Malla.Plugins.Request.malla_request/3` to intercept requests. The callback runs **on the called service**, so the interceptor plugins (authentication, rate limiting, validation) belong in the `plugins:` of the service that receives the requests, not of the one that sends them. The calling service only needs `Malla.Plugins.Request`.

An interceptor receives the name of the function, its arguments and the options of the request. It can return:

- `:cont` to let the request go on;
- `{:cont, [fun, args, opts]}` to go on with a modified request (all three, as a list);
- anything else, which is returned to the caller **instead of calling your function**, as the answer of the request.

### Simple Authentication Plugin

```elixir
defmodule MyApp.AuthPlugin do
  use Malla.Plugin, plugin_deps: [Malla.Plugins.Request]

  defcb malla_request(fun, args, opts) do
    case Keyword.get(opts, :auth_token) do
      nil ->
        {:error, Malla.Status.public(:unauthorized)}

      token ->
        # Add the user to the options for the plugins below, and for the log
        {:cont, [fun, args, Keyword.put(opts, :user_id, "user-" <> token)]}
    end
  end
end
```

Add it to the service that receives the requests:

```elixir
defmodule MyApp.UserService do
  use Malla.Service,
    global: true,
    plugins: [MyApp.AuthPlugin, Malla.Plugins.Request]

  def get_user(1), do: {:ok, %{id: 1, name: "Ann"}}
end
```

The caller only passes the token as an option:

```elixir
req MyApp.UserService.get_user(1), auth_token: token
```

**What an interceptor's error looks like to the caller.** The error returned by an interceptor does not go through the default `malla_request/3`, so it is not normalized on the called service. It reaches the caller as it was returned, and the caller turns it into a status with its own `status/1` clauses. A built-in reason such as `:unauthorized` works anywhere, but a custom reason such as `{:rate_limited, 5}` would become `"internal_error"` unless the *caller* also defines a clause for it. The simplest way to avoid that is for the interceptor to return a ready-made status, as above: a `%Malla.Status{}` is passed through as it is.

### Composing Multiple Plugins

Interceptors form a normal callback chain: they are called in the order of the service's `plugins:` list, and the default implementation of `Malla.Plugins.Request` comes last, because each of them declares `plugin_deps: [Malla.Plugins.Request]`.

```elixir
defmodule MyApp.APIGatewayService do
  use Malla.Service,
    global: true,
    plugins: [
      MyApp.ValidationPlugin,    # called first: validate input
      MyApp.AuthPlugin,          # called second: authenticate (adds :user_id to opts)
      MyApp.RateLimitPlugin      # called third: it can read :user_id
    ]

  def create_user(params), do: {:created, params}
end
```

A plugin that needs the result of another one (the rate limiter needs the `:user_id` that the auth plugin adds) must be called **after** it. Remember that a plugin is called *before* the plugins it depends on, so `plugin_deps: [AuthPlugin]` would put the rate limiter *above* the auth plugin, which is the wrong way round. Control it with the order of `plugins:`, as above (see [Plugins](../04-plugins.md#order-of-independent-plugins)).

### More Plugin Examples

**Rate limiting plugin:**

```elixir
defmodule MyApp.RateLimitPlugin do
  use Malla.Plugin, plugin_deps: [Malla.Plugins.Request]

  defcb malla_request(fun, _args, opts) do
    user_id = Keyword.get(opts, :user_id)

    if rate_limit_exceeded?(user_id, fun) do
      {:error, Malla.Status.public({:rate_limited, retry_after: 60})}
    else
      :cont
    end
  end

  defp rate_limit_exceeded?(_user_id, _fun), do: false
end
```

For `Malla.Status.public/1` to produce a nice status for `{:rate_limited, ...}`, the called service (where this plugin runs) needs a `status/1` clause for it (see "Errors").

**Validation plugin:**

```elixir
defmodule MyApp.ValidationPlugin do
  use Malla.Plugin, plugin_deps: [Malla.Plugins.Request]

  defcb malla_request(:create_user, [params], _opts) do
    cond do
      not is_map(params) -> {:error, Malla.Status.public({:parameter_invalid, :params})}
      not Map.has_key?(params, :email) -> {:error, Malla.Status.public({:parameter_missing, :email})}
      true -> :cont
    end
  end

  defcb malla_request(_fun, _args, _opts), do: :cont
end
```

`{:parameter_invalid, ...}` and `{:parameter_missing, ...}` are built into `Malla.Plugins.Status` (code 400).

Always finish interceptors with a catch-all clause that returns `:cont`; without it a request for another function raises `FunctionClauseError` in the called service and reaches the caller as an `internal_error`.

See the [Callbacks guide](../05-callbacks.md) for more on how plugin chains work.

## Errors

Errors are normalized through `Malla.Status` (see [Status Handling](../09-observability/02-status-handling.md)):

```elixir
defmodule MyApp.OrderService do
  use Malla.Service, plugins: [Malla.Plugins.Request]
  use Malla.Request
  use Malla.Tracer

  defcb process_order(order_id) do
    case req MyApp.PaymentService.charge_order(order_id) do
      {:ok, payment} ->
        {:ok, payment}

      {:error, %Malla.Status{status: "service_not_available"}} ->
        # The service is not running anywhere (after the retries)
        {:error, :payment_service_down}

      {:error, %Malla.Status{status: "insufficient_funds"} = status} ->
        # An error that the payment service defined
        warning("Insufficient funds", order_id: order_id, status: inspect(status))
        {:error, :payment_failed}

      {:error, %Malla.Status{} = status} ->
        error("Payment processing error", status: inspect(status))
        {:error, :payment_error}
    end
  end
end
```

### Where the statuses come from

- A handler that returns `{:error, term}` is normalized **on the called service** by `Malla.Status.public/1`: the `status/1` callback chain of that service is asked first. If a clause matches, the status is built from it; if none does, `status_public/1` answers: it logs the whole term with a reference and answers `"internal_error"` with `info: "Internal reference 1234"`. So the caller never sees the internals of an error that nobody described.
- The transport errors reach the caller as bare reasons and are normalized **on the caller**: `:malla_service_not_available` becomes `"service_not_available"` (`code: 500`). An exception raised in the called function, a timeout, a lost connection, or a called service without `Malla.Plugins.Request` arrive as `{:malla_rpc_error, ...}`; it has no built-in clause on purpose (its text may carry internals), so it becomes `"internal_error"` with a logged reference.
- Whatever the handler returns that is not in the response table is an `"internal_error"` too.

### Common statuses

- `"service_not_available"` - the service is not running on any node (or the target is paused).
- `"internal_error"` - an exception or timeout in the call, an invalid handler response, or **any error with no `status/1` clause**. The details are in the log of the node that produced it, under the reference in `info`.
- The ones built into `Malla.Plugins.Status` when your handler returns them: `"not_found"` (`:not_found`), `"unauthorized"`, `"forbidden"`, `"conflict"`, `"timeout"` (`:timeout`, 408), and so on.

An RPC timeout is **not** `"timeout"`: it is an `"internal_error"`. Statuses such as `"validation_failed"` or `"insufficient_funds"` do not exist unless your code defines them.

### Defining your own errors

Add `status/1` clauses to the service that produces the error (the called service) with `defcb`:

```elixir
defmodule MyApp.PaymentService do
  use Malla.Service, global: true, plugins: [Malla.Plugins.Request]

  def charge_order(_order_id), do: {:error, :insufficient_funds}

  defcb status(:insufficient_funds),
    do: [info: "Insufficient funds", code: 402]

  # Always end with a catch-all that continues the chain
  defcb status(_), do: :cont
end
```

`:insufficient_funds` becomes `%Malla.Status{status: "insufficient_funds", info: "Insufficient funds", code: 402}`. Without the clause it would be an `"internal_error"` with a reference.

## Logging

Both sides log each request at `info` level (`REQ for ...` and `REQ Incoming ...`) through `Malla.Tracer`. The arguments are logged with secret-looking values replaced: when the name of the function says it handles a secret (`set_password`, `login`, ...) all of its arguments are hidden, and otherwise the values of keys that look secret (`password`, `token`, `secret`, `api_key`, ...) and the password of any URL are replaced by `"[redacted]"`.

## Telemetry

Requests emit telemetry events for monitoring:

### `[:malla, :request, :out]`

Emitted on the calling side when a request completes.

**Measurements**:
- `:counter` - Always 1
- `:duration` - Request duration in microseconds

**Metadata**:
- `:target` - Target service name (a string)
- `:op` - Operation/function name
- `:result` - The tag of the answer (`:ok`, `:created`, `:error`, `:status`)
- plus `:service`, `:node`, `:host` and `:cluster`, the metadata of the calling service

### `[:malla, :request, :in]`

Emitted on the called side when a request completes.

**Measurements**: Same as `:out`
**Metadata**: `:op`, `:result` and the standard fields of the called service (no `:target`). Not emitted for requests that an interceptor answered, or that were rejected because the service was not running.

### Example Handler

```elixir
:telemetry.attach(
  "malla-request-handler",
  [:malla, :request, :out],
  fn _event, measurements, metadata, _config ->
    %{duration: duration} = measurements
    %{target: target, op: op} = metadata

    # Log slow requests
    if duration > 1_000_000 do
      require Logger
      Logger.warning("Slow request: #{target}.#{op} took #{duration} microseconds")
    end
  end,
  nil
)
```

## See Also

- [Remote Calls](03-remote-calls.md) - Lower-level RPC mechanisms
- [Status Handling](../09-observability/02-status-handling.md) - Error normalization and `Malla.Status` protocol
- [Tracing](../09-observability/01-tracing.md) - The instrumentation API and tracer plugins
- [Plugins](../04-plugins.md) - Plugin system overview
- [Callbacks](../05-callbacks.md) - Callback chain mechanics
