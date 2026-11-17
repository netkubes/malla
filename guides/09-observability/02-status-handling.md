# Status and Error Handling

Malla provides a system for creating **standardized status and error responses**. This keeps communication between services consistent, especially when handling errors, and keeps internal details of errors from reaching clients.

The system has two parts:
1.  **`Malla.Status`**: the module that defines the `t:Malla.Status.t/0` struct and the functions that convert the values your code returns into it.
2.  **`Malla.Plugins.Status`**: a plugin with a set of common, ready-made status patterns (many of them HTTP-like) and an extensible callback interface for defining your own.

The [Request Handling](../08-distribution/04-request-handling.md) protocol uses it to normalize the errors and statuses it returns. `Malla.Plugins.Request` depends on `Malla.Plugins.Status`, so a service with the request plugin has it.

## The Malla.Status Struct

All standardized responses are `t:Malla.Status.t/0` structs, with these fields:

-   `status`: a string identifier (e.g., `"not_found"`).
-   `info`: a human-readable message.
-   `code`: a number, typically corresponding to an HTTP status code (e.g., `404`). It is `0` when nothing sets it.
-   `data`: a map with additional structured data. Keys and values are strings.
-   `metadata`: a map with service-level metadata (e.g., node, version). Keys and values are strings when they come from a `status/1` clause.

## How It Works

The conversion is driven by the `c:Malla.Plugins.Status.status/1` callback of the service:

1.  Your code produces a term, such as `{:error, :user_not_found}` (the term the status system sees is `:user_not_found`).
2.  `Malla.Status` calls `status/1` on the callback chain of the service, with the term.
3.  The first module of the chain that answers something other than a continuation (`:cont`, `:continue`) wins. It returns a description: a string, or a keyword list.
4.  `Malla.Status` builds the struct from the description and calls `status_metadata/1` on the chain, which can modify it.

The service must have `Malla.Plugins.Status` in its chain for these callbacks to exist (`Malla.Plugins.Request` brings it in).

```elixir
defmodule MyService do
  use Malla.Service,
    plugins: [Malla.Plugins.Status]
end
```

### Built-in Status Patterns

With the plugin included, many common statuses work out of the box. For example, `:not_found` becomes a `Malla.Status` with `status: "not_found"`, `code: 404` and `info: "Not found"`.

The `status` field is the atom (or the first element of the tuple) turned into a string, unless the clause sets `:status`. This is the complete list of patterns that `Malla.Plugins.Status` implements:

| Input pattern | `code` | `info` |
| :--- | :--- | :--- |
| `:ok` | 200 | Success |
| `{:ok_data, data}` | 200 | Success (`data` is a map or keyword list, put in the `data` field) |
| `:created` | 201 | Created |
| `:deleted` | 200 | Deleted |
| `:normal_termination` | 200 | Normal termination |
| `:redirect` | 307 | Redirect |
| `:bad_request` | 400 | Bad Request |
| `:content_type_invalid` | 400 | Content type is invalid |
| `{:field_invalid, field}` | 400 | Field '...' is invalid |
| `{:field_missing, field}` | 400 | Field '...' is missing |
| `{:field_unknown, field}` | 400 | Field '...' is unknown |
| `:file_too_large` | 400 | File too large |
| `:invalid_parameters` | 400 | Invalid parameters |
| `{:parameter_invalid, param}` | 400 | Invalid parameter '...' |
| `{:parameter_missing, param}` | 400 | Missing parameter '...' |
| `{:request_op_unknown, op}` | 400 | Request OP unknown: ... |
| `:request_body_invalid` | 400 | The request body is invalid |
| `{:syntax_error, field}` | 400 | Syntax error: '...' |
| `:token_invalid` | 400 | Token is invalid |
| `:token_expired` | 400 | Token is expired |
| `:unauthorized` | 401 | Unauthorized |
| `:forbidden` | 403 | Forbidden |
| `:not_found` | 404 | Not found |
| `:resource_invalid` | 404 | Invalid resource |
| `{:resource_invalid, resource}` | 200 | Invalid resource '...' |
| `{:resource_invalid, group, resource}` | 200 | Invalid resource '...' (group |
| `{:method_not_allowed, method}` | 405 | Method not allowed: '...' |
| `:verb_not_allowed` | 405 | Verb is not allowed |
| `:timeout` | 408 | Timeout |
| `:conflict` | 409 | Conflict |
| `:not_allowed` | 409 | Not allowed |
| `:service_not_found` | 409 | Service not found |
| `{:service_not_found, service}` | 409 | Service '...' not found |
| `:gone` | 410 | Gone |
| `:unprocessable` | 422 | Unprocessable |
| `:internal_error` | 500 | Internal error (`data.node` is the node) |
| `{:internal_error, ref}` | 500 | Internal error: ref (`data.ref` and `data.node`) |
| `{:malla_exception, exception}` | 500 | `MallaSpans EXCEPTION: ...` |
| `{:malla_exit, reason}` | 500 | `MallaSpans EXIT: ...` |
| `:service_not_available` | 500 | RPC service unavailable |
| `:malla_service_not_available` | 500 | RPC service unavailable; the `status` field is `"service_not_available"` |
| `:not_implemented` | 501 | Not implemented |
| `{:service_not_available, service}` | 503 | Service '...' not available (`data.service`) |
| `{:tls_alert, error}` | 0 | `Error TLS: ...` (it answers a string, so there is no code) |

A few of these values are odd (the two `:resource_invalid` tuples answer `200`, the `:service_not_available` atom answers `500` while the tuple form answers `503`, the info of the three-element `:resource_invalid` has an unbalanced parenthesis). They are what the code does today; if you rely on a code, set the clause yourself (see below) rather than on the built-in one.

An exception raised on a remote node (`{:malla_rpc_error, {exception, text}}`, see `Malla.remote/4`) has no built-in pattern on purpose: through `Malla.Status.public/2` it reaches `c:Malla.Plugins.Status.status_public/1`, which logs it under a reference and answers `"internal_error"`, so its text never reaches the client. A service that wants a specific status for some exceptions (a database timeout, say) adds a `status/1` clause for `{:malla_rpc_error, {exception, _text}}`.

### Defining Custom Statuses

You define your own application-specific statuses by implementing the `c:Malla.Plugins.Status.status/1` callback in your service or in a plugin that depends on `Malla.Plugins.Status`.

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

  # A string is a shortcut for [info: string]
  defcb status(:maintenance), do: "The service is in maintenance"

  # IMPORTANT: always include a catch-all that continues the chain,
  # so the built-in patterns and other plugins can handle theirs.
  defcb status(_), do: :cont
end
```

Now, if a function in `MyService` returns `{:error, :duplicate_record}`, Malla builds `%Malla.Status{status: "duplicate_record", info: "A record with this identifier already exists.", code: 409}`.

The `c:Malla.Plugins.Status.status/1` callback can return a keyword list with the following keys:
-   `:info`: the human-readable message (becomes the `info` field).
-   `:code`: the numeric/HTTP status code (an integer).
-   `:status`: a string to override the default status identifier.
-   `:data`: a map or keyword list of additional structured data. Keys and values are converted to strings.
-   `:metadata`: a map or keyword list of service metadata. Keys and values are converted to strings.

### `:cont` and `:continue`

To say "I do not handle this term", a `status/1` clause returns `:cont`, like any other callback. The dispatcher also accepts `:continue` as the same thing, and the built-in catch-all of `Malla.Plugins.Status` (the bottom of the `status/1` chain) returns `:continue`. That is the value `Malla.Status` receives when nobody described the term: it then falls back (`status_public/1` for `public/2`, a guess for `status/2`). So:

- In your own clauses use `:cont` (`:continue` also works).
- You do not need to return `:continue` yourself; the last module does.
- A `status/1` implementation without a catch-all clause raises `FunctionClauseError` for terms it does not match, so always add `defcb status(_), do: :cont`.

### Adding Metadata: `status_metadata/1`

After a status has been built, `c:Malla.Plugins.Status.status_metadata/1` is called with the `%Malla.Status{}` and returns it, so a service or plugin can add information to every status: the node, a version, a support contact. The default returns the status unchanged. Return `:cont` (or `{:cont, status}`) to pass it on:

```elixir
defmodule MyService do
  use Malla.Service, plugins: [Malla.Plugins.Status]

  defcb status_metadata(%Malla.Status{status: "internal_error"} = status) do
    {:cont, %{status | metadata: Map.put(status.metadata, "support", "support@example.com")}}
  end

  defcb status_metadata(_status), do: :cont
end
```

`status_metadata/1` is also applied to a `%Malla.Status{}` that you pass to `Malla.Status.status/2` or `Malla.Status.public/2` (the two-argument forms).

### Customizing What Is Exposed: `status_public/1`

`Malla.Status.public/2` is for answers that go to external clients. If no `status/1` clause describes the term, it calls `c:Malla.Plugins.Status.status_public/1`. The default logs the whole term with a reference number and answers `%Malla.Status{status: "internal_error", info: "Internal reference 1234", code: 500}`, so the details stay in your log.

Override it to expose some terms, or to log differently. Return a `%Malla.Status{}`, or `:cont` to use the default:

```elixir
defcb status_public({:expose, message}),
  do: %Malla.Status{status: "exposed", info: to_string(message), code: 400}

defcb status_public(_), do: :cont
```

## `status/2` vs `public/2`

`Malla.Status` has two conversion functions with a service ID and one term:

-   `Malla.Status.status(srv_id, term)`: when no `status/1` clause matches, it **guesses**: the `status` is the atom (or the first element of a tuple) as a string, and the `info` is the term (or the second element of a two-element tuple) as a string. Use it where full details are fine, such as logs and debugging.
-   `Malla.Status.public(srv_id, term)`: when no clause matches it calls `status_public/1`, which hides the details. Use it for responses that leave your system. The [Request Handling](../08-distribution/04-request-handling.md) protocol uses it.

Both return a `%Malla.Status{}` you pass in as it is (adding metadata). The arities without the service ID (`Malla.Status.status/1`, `Malla.Status.public/1`) take the service ID from the process dictionary. Be aware that `Malla.Status.status/1` calls `public/2`, not `status/2`: it hides unmatched terms like `public/1` does.

```elixir
Malla.Status.status(MyService, {:not_found, "no such user"})
# => %Malla.Status{status: "not_found", info: "no such user", code: 0, ...}
#    (no clause matches a two-element tuple, so it is a guess)

Malla.Status.public(MyService, {:badarg, %{secret: 1}})
# => %Malla.Status{status: "internal_error", info: "Internal reference 4821", code: 500}
```
