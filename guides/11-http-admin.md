# HTTP Admin Server

`Malla.Plugins.Httpd` is a dependency-free HTTP server plugin built on Erlang's
`:inets` `httpd` (already part of OTP). It is intended for administrative
surfaces — Prometheus scraping, Kubernetes health probes, internal
introspection — where pulling in a full web stack would be overkill.

> #### Do not expose this port {: .warning}
>
> The server has **no authentication and no TLS**, and the plugin sets no bind address, so it listens on **all network interfaces** (requests to a non-loopback address of the machine are answered, not only to `127.0.0.1`). Every route you add is open to whoever can reach the port. With `Malla.Plugins.Httpd.Lifecycle`, `GET /stop` starts a drain of all the services of the node (see below), so anyone who can reach the port can take the node out of service. Keep the port inside the pod or the private network: do not publish it through a public service, ingress or load balancer, and restrict it with network policies or a firewall.

## Why use it?

- **No HTTP dependencies**: it uses only `:inets`, which ships with OTP. No Cowboy, no Plug.
- **Malla-native**: the request entry point is a `c:Malla.Plugins.Httpd.httpd_request/4` callback in your service, so all of Malla's plugin composition applies.
- **Multi-listener**: one service can expose several ports (e.g. `:9100` for metrics, `:8080` for probes) by listing multiple `:malla_httpd` entries.
- **Kubernetes-ready**: the bundled `Malla.Plugins.Httpd.Lifecycle` implements `/is_live`, `/is_ready`, `/stop`, and `/node`.

It is an optional plugin: it is only active in services that list it in their `plugins:`. Nothing is started unless you opt in.

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

`httpd_request/4` is **optional**. `Malla.Plugins.Httpd` provides a default that answers `404` to everything, so a service that only wants the lifecycle endpoints does not have to define it. If your service defines it, the default is reached only when your clauses return `:cont`; add a catch-all `defcb httpd_request(_name, _method, _path, _data), do: :cont` to let the plugins below (such as `Malla.Plugins.Httpd.Lifecycle`) answer the paths you do not handle. Without a catch-all, a request that matches no clause raises `FunctionClauseError`, and the client gets a `500` with the body `Error`.

## Configuration

Configuration lives under the `:malla_httpd` key. Options:

| Option | Type | Default | Notes |
|---|---|---|---|
| `:port` | `pos_integer` | `3500` (first entry), `3501`, ... | Listening port |
| `:name` | `atom \| string` | `"default"` (first), `"default-1"`, ... | Needed to tell the listeners apart when a service has several |

Any other option is rejected when the service starts.

### Multiple listeners

```elixir
use Malla.Service,
  plugins: [Malla.Plugins.Httpd],
  malla_httpd: [port: 9100, name: "metrics"],
  malla_httpd: [port: 8080, name: "probes"]
```

Each entry gets its own supervised `httpd` child. The same `c:Malla.Plugins.Httpd.httpd_request/4` callback handles all of them: dispatch on `path`, or on the `name` first argument to differentiate per listener:

```elixir
defcb httpd_request("metrics", :get, "/metrics", _data), do: {:reply, code: 200, body: "..."}
defcb httpd_request("probes", :get, "/ready", _data), do: {:reply, code: 200}
defcb httpd_request(_name, _method, _path, _data), do: :cont
```

### Runtime reconfigure

`MyService.reconfigure(malla_httpd: [port: 9101, name: "metrics"])` changes the configuration, and since the `:malla_httpd` value changed, `plugin_updated/3` asks for a restart of the plugin, which stops the listeners and starts them again with the new configuration. **The update replaces all the `:malla_httpd` entries**: pass every listener you want to keep. See [Reconfiguration](07a-reconfiguration.md) for the broader mechanism.

## Lifecycle plugin (Kubernetes probes)

`Malla.Plugins.Httpd.Lifecycle` adds routes that wire Kubernetes probes directly into Malla's readiness and drain callbacks:

| Route | Maps to | Use |
|---|---|---|
| `GET /node` | `node()` | Debug / identity |
| `GET /is_live` | `Malla.Service.is_live?/1` on every local service | `livenessProbe` |
| `GET /is_ready` | `Malla.Service.is_ready?/1` on every local service | `readinessProbe` |
| `GET /stop` | `httpd_lifecycle_drain_start/0`, then `Malla.Service.drain_all_local/0` (by `:priority`, lowest first), then `httpd_lifecycle_drain/0` | `preStop` hook |

`/is_live` and `/is_ready` answer `200`, or `500` with the first service that fails in the body. `/stop` does **not** stop the service or the node: it calls the drain callbacks and answers `200` when every service reports drained (it retries once per second, up to 10 times, so the request can take 10 seconds, and answers `500` if the drain does not complete). Stopping the node is up to whoever called it (for example, Kubernetes after the `preStop` hook returns).

```elixir
defmodule MyService do
  use Malla.Service,
    plugins: [Malla.Plugins.Httpd.Lifecycle],
    priority: 1000,
    malla_httpd: [port: 8080]

  # Optional: gate /stop on your own drain work
  defcb httpd_lifecycle_drain() do
    if pending_work?(), do: false, else: true
  end

  defp pending_work?(), do: false
end
```

`Malla.Plugins.Httpd.Lifecycle` declares `Malla.Plugins.Httpd` as a plugin dependency, so you do not list both. It answers its own routes and returns `:cont` for the rest of the paths, so your own `httpd_request/4` in the service (which is called first) must also return `:cont` for them.

The `:priority` of the service decides when it is drained relative to the other services of the node; give the HTTP service a high one so it keeps answering while the others drain.

## Callbacks

### `httpd_request(name, method, path, data)` — optional

Called for every incoming request. `name` is the `:name` of the `:malla_httpd` entry that received the request (a string: `"default"` when unset). `method` is `:get`, `:post`, `:put`, `:head` or `:delete` (anything else arrives as a string). `path` includes any query string. Return `{:reply, response}` where `response` is a keyword list:

```elixir
{:reply, code: 200, body: "hello", content_type: "text/plain"}
```

Recognized keys: `:code`, `:body`, plus any `httpd` response header (`:content_type`, `:cache_control`, `:location`, `:etag`, `:expires`, ...), whose values are strings. See `t:Malla.Plugins.Httpd.response/0`.

Return `:cont` to pass the request to the next plugin in the chain. `Malla.Plugins.Httpd`'s own implementation, at the bottom, answers `404`.

If the callback raises, the client gets a `500` with the body `Error` and the exception is logged.

Utilities for working with `data`:

```elixir
Malla.Plugins.Httpd.get_headers(data)  # => [{"host", "..."}, ...]
Malla.Plugins.Httpd.get_body(data)     # => "request body as a string"
```

### `httpd_lifecycle_drain_start/0` — optional

Overridable when using `Malla.Plugins.Httpd.Lifecycle`. Called once by `/stop` before any service drains: the place to report not ready, stop consumers or close listeners that should take no new work. Its return value is ignored; the default does nothing.

### `httpd_lifecycle_drain/0` — optional

Overridable when using `Malla.Plugins.Httpd.Lifecycle`. Return `true` once your service is genuinely drained, `false` to be asked again a second later; `/stop` gives up with `500` after 10 attempts.

## Testing

A service that uses the plugin can be tested with Erlang's built-in `:httpc` client (`:inets` is already running):

```elixir
defmodule MyService.HttpTest do
  use ExUnit.Case

  defmodule Svc do
    use Malla.Service,
      plugins: [Malla.Plugins.Httpd.Lifecycle],
      silent: true,
      malla_httpd: [port: 37_013]
  end

  test "answers the probes" do
    start_supervised!(Svc)
    # Returns when the service has started its plugins, so the port is open
    {:ok, %{running_status: :running}} = Malla.Service.get_service_info(Svc)

    {:ok, {{_, 200, _}, _headers, ~c"nonode@nohost"}} =
      :httpc.request(:get, {~c"http://127.0.0.1:37013/node", []}, [], [])
  end
end
```

`start_link/1` returns before the plugins start, so wait for `get_service_info/2` as above before making the first request. The `/node` body is the name of the node, so it is `nonode@nohost` in a test that is not distributed.
