# Status and Error Handling

Malla provides a system for creating **standardized status and error responses**. This ensures that communication between services is consistent and predictable, especially when handling errors.

The system is composed of two main parts:
1.  **`Malla.Status`**: The core module that defines the `t:Malla.Status.t/0` struct and provides functions for converting internal responses into this standardized structure.
2.  **`Malla.Plugins.Status`**: A plugin that provides a set of common, out-of-the-box status patterns (like HTTP error codes) and an extensible callback interface for defining your own custom statuses.

The status system is automatically integrated into the [Request Handling](../08-distribution/04-request-handling.md) protocol, normalizing all responses via `Malla.Status.public/1`.

## The Malla.Status Struct

All standardized responses are converted into a `t:Malla.Status.t/0` struct, which has the following fields:

-   `status`: A string identifier for the status (e.g., `"not_found"`).
-   `info`: A human-readable message describing the status.
-   `code`: A numerical code, typically corresponding to an HTTP status code (e.g., `404`).
-   `data`: A map containing additional structured data related to the status.
-   `metadata`: A map for service-level metadata (e.g., node, version).

## How It Works

The conversion process is driven by the `c:Malla.Plugins.Status.status/1` callback, which is implemented by the `Malla.Plugins.Status` plugin. This is automatically used by the [Request Handling](../08-distribution/04-request-handling.md) protocol to normalize all responses.

1.  A service function returns an internal status, such as `{:error, :user_not_found}`.
2.  Malla invokes the `c:Malla.Plugins.Status.status/1` callback on the service's plugin chain.
3.  The first plugin (or service) that matches the pattern returns a description.
4.  `Malla.Status` uses this description to build the final `t:Malla.Status.t/0` struct.

## Using the Status Plugin

To use the built-in status patterns and enable custom ones, add the `Malla.Plugins.Status` plugin to your service.

```elixir
defmodule MyService do
  use Malla.Service,
    plugins: [Malla.Plugins.Status]
end
```

### Built-in Status Patterns

With the plugin included, many common statuses work out of the box. For example, if your service returns `{:error, :not_found}`, it will be automatically converted to a `Malla.Status` struct with `code: 404` and `info: "Not found"`.

Some of the built-in patterns include:

| Input Pattern | HTTP Code | Message |
| :--- | :--- | :--- |
| `:ok` | 200 | Success |
| `:created` | 201 | Created |
| `:bad_request` | 400 | Bad Request |
| `{:field_missing, field}` | 400 | Field is missing |
| `:unauthorized` | 401 | Unauthorized |
| `:forbidden` | 403 | Forbidden |
| `:not_found` | 404 | Not found |
| `:conflict` | 409 | Conflict |
| `:timeout` | 408 | Timeout |
| `:internal_error` | 500 | Internal error |
| `:not_implemented` | 501 | Not implemented |
| `:service_not_available` | 503 | Service not available |

### Defining Custom Statuses

You can define your own application-specific statuses by implementing the `c:Malla.Plugins.Status.status/1` callback in your service.

```elixir
defmodule MyService do
  use Malla.Service, plugins: [Malla.Plugins.Status]

  # Handle a custom error tuple: {:validation_error, field_name}
  defcb status({:validation_error, field}) do
    [
      info: "Validation failed on field: #{field}", 
      code: 422, # Unprocessable Entity
      data: [invalid_field: field]
    ]
  end

  # Handle a simple custom atom
  defcb status(:duplicate_record) do
    [
      info: "A record with this identifier already exists.",
      code: 409 # Conflict
    ]
  end

  # IMPORTANT: Always include a catch-all that continues the chain,
  # so that other plugins (including the base status plugin) can handle their own statuses.
  defcb status(_), do: :continue
end
```

Now, if a function in `MyService` returns `{:error, :duplicate_record}`, Malla will automatically generate the appropriate `Malla.Status` response.

The `c:Malla.Plugins.Status.status/1` callback can return a keyword list with the following keys:
-   `:info`: The human-readable message (becomes the `info` field).
-   `:code`: The numeric/HTTP status code.
-   `:status`: A string to override the default status identifier.
-   `:data`: A map or keyword list of additional structured data.
-   `:metadata`: A map or keyword list of service metadata.

## `status/2` vs `public/2`

The `Malla.Status` module has two main functions for conversion:

-   `Malla.Status.status(srv_id, internal_status)`: Converts any internal status into a `Malla.Status` struct. It's useful for internal logging and debugging where full error details are acceptable.
-   `Malla.Status.public(srv_id, internal_status)`: Designed for responses that will be exposed to external clients. For unknown or sensitive Erlang/Elixir runtime errors (e.g., `:badarg`), this function generates a sanitized response with a reference ID (e.g., `"Internal reference 1234"`) while logging the full error details internally.

The [Request Handling](../08-distribution/04-request-handling.md) protocol uses `public/2` by default to ensure that internal implementation details are not accidentally leaked to clients.
