# Request Handling

Malla's _request handling system_ provides a structured protocol for inter-service communication across distributed nodes. It builds on top of the basic RPC mechanisms to add automatic service discovery, distributed tracing, standardized responses, retry logic, and plugin-based request interception.

## Why Request Handling?

While Malla provides basic remote call capabilities via `Malla.remote/4`, the request handling system adds critical features for production distributed systems:

- **Standardized Responses**: Enforces consistent response formats across all services
- **Distributed Tracing**: Automatic span propagation for observability
- **Automatic Retries**: Configurable retry logic for transient failures
- **Plugin Interception**: Cross-cutting concerns like authentication, rate limiting, and validation
- **Telemetry Integration**: Built-in metrics for monitoring request/response patterns
- **Error Normalization**: Consistent error handling via `Malla.Status`

This makes inter-service communication predictable, observable, and maintainable at scale.

To use this system, you need to include plugin `Malla.Plugins.Request` both the calling and the called services. This plugin also depends on both
`Malla.Plugins.Tracer` and `Malla.Plugins.Status`, since it uses both the [Tracing System ](../09-observability/01-tracing.md) and the [Status System](../09-observability/02-status-handling.md).

## Basic Usage

### Simple Request/Response

Start with basic inter-service communication using the `req` macro:

```elixir
# Define a service that provides user data
defmodule UserService do
  use Malla.Service, global: true, plugins: [Malla.Plugins.Request]

  def get_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def list_users() do
    users = Repo.all(User)
    {:ok, users}
  end
end

# Call from another service
defmodule APIService do
  use Malla.Service, plugins: [Malla.Plugins.Request]
  import Malla.Request, only: [req: 1]

  def fetch_user(user_id) do
    # Use req to make the call - it handles routing, tracing, and error normalization
    case req UserService.get_user(user_id) do
      {:ok, user} -> 
        {:ok, format_user(user)}
      {:error, %Malla.Status{status: "not_found"}} -> 
        {:error, :user_not_found}
    end
  end

  def fetch_all_users() do
    {:ok, users} = req UserService.list_users()
    {:ok, Enum.map(users, &format_user/1)}
  end
end
```

The `req` macro automatically:
- Discovers which node is running `UserService`
- Routes the call to that node
- Creates distributed trace spans
- Normalizes errors into `Malla.Status` structs
- Emits telemetry metrics

### Alternative Syntax

You can also use the explicit function form:

```elixir
# Equivalent to: req UserService.get_user(123)
Malla.Request.request(UserService, :get_user, [123])

# With options
Malla.Request.request(UserService, :get_user, [123], timeout: 10_000)
```

## Response Protocol

Request handlers should return one of these standardized formats:

### Success Responses

```elixir
defmodule ProductService do
  use Malla.Service, global: true

  # Success with no data
  def health_check(_params) do
    :ok
  end

  # Success with data (data should be serializable: maps, lists, primitives)
  def get_product(product_id) do
    product = Repo.get!(Product, product_id)
    {:ok, product}
  end

  # Resource created with data
  def create_product(params) do
    {:ok, product} = Repo.insert!(Product.changeset(%Product{}, params))
    {:created, product}
  end
end
```

**Valid success responses:**
- `:ok` - Success with no data
- `:created` - Resource created with no data
- `{:ok, data}` - Success with data
- `{:created, data}` - Resource created with data

### Error Responses

```elixir
defmodule ProductService do
  use Malla.Service, global: true

  def get_product(product_id) do
    case Repo.get(Product, product_id) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  def update_product(product_id, params) do
    product = Repo.get!(Product, product_id)
    
    case Product.changeset(product, params) |> Repo.update() do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:validation_failed, changeset}}
    end
  end

  def check_stock(product_id, quantity) do
    product = Repo.get!(Product, product_id)
    
    if product.stock >= quantity do
      :ok
    else
      {:status, {:insufficient_stock, available: product.stock}}
    end
  end
end
```

**Valid error responses:**
- `{:error, term}` - Error (normalized via `Malla.Status.public/1`, marks span as error)
- `{:status, term}` - Custom status (normalized via `Malla.Status.public/1`)

All errors are automatically converted to `t:Malla.Status.t/0` structs with standard fields.

## How Requests Work

### Request Flow

When you call `req UserService.get_user(123)`:

1. **Client Side**:
   - Creates a "request-out" span for distributed tracing
   - Invokes `c:Malla.Plugins.Request.malla_request/3` callback (plugins can intercept here)
   - Uses `Malla.remote/4` to make RPC call to the node running UserService

2. **Server Side**:
   - Receives call to `c:Malla.Plugins.Request.malla_request/3`
   - Creates "request-in" span (child of request-out span)
   - Calls your function: `get_user(123)`
   - Normalizes response via `Malla.Status`
   - Emits telemetry metrics

3. **Client Side (response)**:
   - Receives normalized response
   - Emits telemetry metrics
   - Returns standardized result

This creates a parent-child trace relationship across nodes for observability.

## Request Options

Both `req/2` and `request/4` accept options:

```elixir
# Timeout control
req UserService.get_user(123), timeout: 5_000

# Direct call (skip RPC, call locally - useful for testing)
req UserService.get_user(123), direct: true

# Pass custom options that plugins can access
req UserService.create_user(params), 
  auth_token: "abc123",
  request_id: UUID.generate()

# All Malla.remote/4 options are supported
req UserService.heavy_operation(data),
  timeout: 30_000,
  retries: 3,
  retry_delay: 1_000
```

See common options for `Malla.remote/4`. Custom options (like `:auth_token`) are passed through to plugins for interception logic.

## Distributed Tracing

Requests automatically propagate trace context across nodes:

```elixir
defmodule OrderService do
  use Malla.Service, plugins: [Malla.Plugins.Request]
  import Malla.Request, only: [req: 1]
  use Malla.Tracer

  def create_order(user_id, items) do
    span [:order_service, :create_order] do
      info("Creating order", user_id: user_id, item_count: length(items))

      # Each req call creates a child span in the distributed trace
      {:ok, _user} = req UserService.get_user(user_id)

      Enum.each(items, fn item ->
        :ok = req ProductService.check_stock(item.product_id, item.quantity)
      end)

      {:ok, payment} = req PaymentService.charge(user_id, calculate_total(items))

      order = insert_order(user_id, items, payment)
      {:created, order}
    end
  end
end
```

This creates a trace hierarchy:

```
order_service:create_order (OrderService, node1)
  ├─ request-out → request-in (UserService, node2)
  │   └─ user_service:get_user
  ├─ request-out → request-in (ProductService, node3)
  │   └─ product_service:check_stock
  ├─ request-out → request-in (ProductService, node3)
  │   └─ product_service:check_stock
  └─ request-out → request-in (PaymentService, node2)
      └─ payment_service:charge
```

See the [Tracing guide](../09-observability/01-tracing.md) for more details.

## Plugin-Based Interception

Plugins can intercept requests by implementing the `c:Malla.Plugins.Request.malla_request/3` callback, enabling cross-cutting concerns without modifying service code.

### Simple Authentication Plugin

```elixir
defmodule AuthPlugin do
  use Malla.Plugin, plugin_deps: [Malla.Plugins.Request]
  use Malla.Tracer

  defcb malla_request(fun, args, opts) do
    case Keyword.get(opts, :auth_token) do
      nil ->
        warning("Missing authentication token")
        {:error, :missing_auth_token}

      token ->
        case verify_token(token) do
          {:ok, user_id} ->
            info("Authenticated", user_id: user_id, operation: fun)
            # Add user_id to opts for downstream use
            opts = Keyword.put(opts, :user_id, user_id)
            {:cont, [fun, args, opts]}

          {:error, reason} ->
            warning("Invalid token", reason: reason)
            {:error, :unauthorized}
        end
    end
  end

  defp verify_token(token), do: {:ok, extract_user_id(token)}
end
```

Add to your service:

```elixir
defmodule APIService do
  use Malla.Service,
    plugins: [Malla.Plugins.Request, AuthPlugin]
  
  use Malla.Request

  def create_user(params) do
    # AuthPlugin will verify the token before this runs
    # If successful, opts will contain :user_id
    req UserService.create_user(params), auth_token: get_auth_token()
  end
end
```

### Composing Multiple Plugins

Plugins execute in order, allowing layered concerns:

```elixir
defmodule APIGatewayService do
  use Malla.Service,
    global: true,
    plugins: [
      ValidationPlugin,    # Runs first - validate input
      AuthPlugin,          # Runs second - authenticate
      RateLimitPlugin,     # Runs third - check rate limits
      LoggingPlugin        # Runs fourth - log request
    ]

  use Malla.Request

  def create_user(params) do
    # By the time we get here:
    # - params have been validated
    # - user has been authenticated
    # - rate limit has been checked
    # - request is being logged
    
    req UserService.create_user(params)
  end
end
```

### More Plugin Examples

**Rate Limiting Plugin:**

```elixir
defmodule RateLimitPlugin do
  use Malla.Plugin,
    plugin_deps: [AuthPlugin]  # Runs after AuthPlugin
  use Malla.Tracer

  defcb malla_request(fun, args, opts) do
    user_id = Keyword.get(opts, :user_id)

    if rate_limit_exceeded?(user_id, fun) do
      warning("Rate limit exceeded", user_id: user_id, operation: fun)
      {:error, {:rate_limited, retry_after: get_retry_after(user_id)}}
    else
      record_request(user_id, fun)
      :cont
    end
  end

  defp rate_limit_exceeded?(user_id, operation), do: false
  defp record_request(user_id, operation), do: :ok
  defp get_retry_after(user_id), do: 60
end
```

**Validation Plugin:**

```elixir
defmodule ValidationPlugin do
  use Malla.Plugin, plugin_deps: [Malla.Plugins.Request]

  defcb malla_request(fun, args, opts) do
    case validate_args(fun, args) do
      :ok -> :cont
      {:error, reason} -> {:error, {:validation_failed, reason}}
    end
  end

  defp validate_args(:create_user, [params]) do
    cond do
      not is_map(params) -> {:error, "params must be a map"}
      not Map.has_key?(params, :email) -> {:error, "email is required"}
      true -> :ok
    end
  end

  defp validate_args(_fun, _args), do: :ok
end
```

See the [Callbacks guide](../05-callbacks.md) for more on how plugin chains work.

## Error Handling

The request protocol normalizes all errors through `Malla.Status`:

```elixir
defmodule OrderService do
  use Malla.Request
  use Malla.Tracer

  def process_order(order_id) do
    case req PaymentService.charge_order(order_id) do
      {:ok, payment} ->
        complete_order(order_id, payment)

      {:error, %Malla.Status{status: "service_not_available"}} ->
        # Service is down - could retry or queue for later
        error("Payment service unavailable")
        {:error, :payment_service_down}

      {:error, %Malla.Status{status: "insufficient_funds"} = status} ->
        # Application-specific error
        warning("Insufficient funds", order_id: order_id, status: status)
        {:error, :payment_failed}

      {:error, %Malla.Status{} = status} ->
        # Unexpected error
        error("Payment processing error", status: status)
        {:error, :payment_error}
    end
  end
end
```

### Common Error Statuses

- `"service_not_available"` - Target service not running
- `"internal_error"` - Unexpected exception occurred
- `"timeout"` - Request timed out
- `"not_found"` - Resource not found
- `"validation_failed"` - Input validation failed
- `"unauthorized"` - Authentication failed
- `"forbidden"` - Authorization failed

See the [Status Handling guide](../09-observability/02-status-handling.md) for more details.

## Telemetry

Requests emit telemetry events for monitoring:

### `[:malla, :request, :out]`

Emitted on the calling side when a request completes.

**Measurements**:
- `:counter` - Always 1
- `:duration` - Request duration in microseconds

**Metadata**:
- `:target` - Target service name
- `:op` - Operation/function name
- `:result` - Result type (`:ok`, `:created`, `:error`, `:status`)

### `[:malla, :request, :in]`

Emitted on the receiving side when request completes.

**Measurements**: Same as `:out`
**Metadata**: Same as `:out` (without `:target`)

### Example Handler

```elixir
:telemetry.attach(
  "malla-request-handler",
  [:malla, :request, :out],
  fn _event, measurements, metadata, _config ->
    %{duration: duration} = measurements
    %{target: target, op: op, result: result} = metadata
    
    # Log slow requests
    if duration > 1_000_000 do
      Logger.warning("Slow request: #{target}.#{op} took #{duration}μs")
    end
    
    # Update metrics
    :prometheus.inc(:malla_requests_total, [target, op, result])
    :prometheus.observe(:malla_request_duration, [target, op], duration)
  end,
  nil
)
```

## See Also

- [Remote Calls](03-remote-calls.md) - Lower-level RPC mechanisms
- [Status Handling](../09-observability/02-status-handling.md) - Error normalization and `Malla.Status` protocol
- [Tracing](../09-observability/01-tracing.md) - Distributed tracing with `Malla.Plugins.Tracer` and span propagation
- [Plugins](../04-plugins.md) - Plugin system overview
- [Callbacks](../05-callbacks.md) - Callback chain mechanics
