# HTTP Admin Server

`Malla.Plugins.Httpd` is a dependency-free HTTP server plugin built on Erlang's
`:inets` `httpd` (already part of OTP). It is intended for administrative
surfaces — Prometheus scraping, Kubernetes health probes, internal
introspection — where pulling in a full web stack would be overkill.

## Why use it?

- **Zero HTTP deps** — uses only `:inets`, already shipped with Malla. No
  Cowboy, no Plug, no compile-time web stack.
- **Malla-native** — the request entry point is a `c:Malla.Plugins.Httpd.httpd_request/4`
  callback in your service. All of Malla's plugin composition, remote calls, and
  lifecycle control apply.
- **Multi-listener** — one service can expose several ports (e.g. `:9100` for
  metrics, `:8080` for probes) by listing multiple `:malla_httpd` entries.
- **Kubernetes-ready** — the bundled `Malla.Plugins.Httpd.Lifecycle` implements
  `/is_live`, `/is_ready`, `/stop`, and `/node` out of the box.

It is an optional plugin: it is only active in services that list it in their
`plugins:`. Nothing is started unless you opt in.

## Quick Start

```elixir
defmodule MyService do
  use Malla.Service,
    plugins: [Malla.Plugins.Httpd],
    malla_httpd: [port: 8080]

  defcb httpd_request(name, method, path, data) do
    body = inspect(%{
      name: name,
      method: method,
      path: path,
      headers: Malla.Plugins.Httpd.get_headers(data),
      body: Malla.Plugins.Httpd.get_body(data)
    })

    {:reply, code: 200, body: body, server: "MyService"}
  end
end

{:ok, _pid} = MyService.start_link()
```

```sh
$ curl -s http://localhost:8080/hello
%{name: "default", method: :get, path: "/hello", headers: [...], body: ""}
```

If no clause matches, the chain falls through to `Malla.Plugins.Httpd`'s
built-in handler, which returns `404`.

## Configuration

Configuration lives under the `:malla_httpd` key. Options:

| Option | Type | Default | Notes |
|---|---|---|---|
| `:port` | `pos_integer` | `3500` (first entry), `3501`, ... | Listening port |
| `:name` | `atom \| string` | `"default"` (first), `"default-1"`, ... | Required when running multiple listeners in one service |

### Multiple listeners

```elixir
use Malla.Service,
  plugins: [Malla.Plugins.Httpd],
  malla_httpd: [port: 9100, name: "metrics"],
  malla_httpd: [port: 8080, name: "probes"]
```

Each entry gets its own supervised `httpd` child. The same
`c:Malla.Plugins.Httpd.httpd_request/4` callback handles both — dispatch on
`path`, or on the `name` first argument to differentiate per-listener:

```elixir
defcb httpd_request("metrics", :get, "/metrics", _data), do: ...
defcb httpd_request("probes",  :get, "/is_ready", _data), do: ...
```

### Runtime reconfigure

`MyService.reconfigure(malla_httpd: [port: 9101, name: "metrics"])` triggers
`plugin_updated/3`, which restarts the listeners when the `:malla_httpd` value
changes. See [Reconfiguration](guides/07a-reconfiguration.md) for the broader
mechanism.

## Lifecycle plugin (Kubernetes probes)

`Malla.Plugins.Httpd.Lifecycle` adds routes that wire Kubernetes probes
directly into Malla's readiness and drain callbacks:

| Route | Maps to | Use |
|---|---|---|
| `GET /node` | `node()` | Debug / identity |
| `GET /is_live` | `Malla.Service.is_live?/1` on every local service | `livenessProbe` |
| `GET /is_ready` | `Malla.Service.is_ready?/1` on every local service | `readinessProbe` |
| `GET /stop` | `Malla.Service.drain/1` on every local service, then `httpd_lifecycle_drain/0` | `preStop` hook |

```elixir
defmodule MyService do
  use Malla.Service,
    plugins: [Malla.Plugins.Httpd.Lifecycle],
    malla_httpd: [port: 8080]

  # Optional: gate /stop on your own drain work
  defcb httpd_lifecycle_drain() do
    if pending_work?(), do: false, else: true
  end
end
```

`Malla.Plugins.Httpd.Lifecycle` declares `Malla.Plugins.Httpd` as a plugin
dependency, so you don't list both.

## Callbacks

### `httpd_request(name, method, path, data)` — required

Called for every incoming request. `name` is the `:name` of the `:malla_httpd`
entry that received the request (as a string — `"default"` when unset, or
whatever you configured). Return `{:reply, response}` where `response` is a
keyword list:

```elixir
{:reply, code: 200, body: "hello", content_type: "text/plain"}
```

Recognized keys: `:code`, `:body`, plus any `httpd` response header
(`:content_type`, `:cache_control`, `:location`, `:etag`, `:expires`, ...). See
`t:Malla.Plugins.Httpd.response/0`.

Return `:cont` to pass the request to the next plugin in the chain.
`Malla.Plugins.Httpd`'s catch-all clause at the bottom returns `404`.

Utilities for working with `data`:

```elixir
Malla.Plugins.Httpd.get_headers(data)  # => [{"host", "..."}, ...]
Malla.Plugins.Httpd.get_body(data)     # => "request body as binary"
```

### `httpd_lifecycle_drain/0` — optional

Overridable when using `Malla.Plugins.Httpd.Lifecycle`. Return `true` once your
service is genuinely drained; `/stop` retries for 10 seconds before giving up
with `500`.

## Testing

See `test/httpd_test.exs` for a multi-server config example and a full
request/response round-trip using Erlang's built-in `:httpc` client (no
external deps).
