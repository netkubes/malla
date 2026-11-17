# Deployment Guide

This guide covers running Malla services in production with Mix releases and Kubernetes: building the release, naming the nodes, connecting them, probes and graceful shutdown, and rolling upgrades.

Malla itself only provides the pieces described below. The parts about Mix releases and Kubernetes manifests are the standard ones for Elixir and Kubernetes, shown here as they apply to Malla; they were not run as part of writing this guide.

## Releases

A Malla service is started like any other process of your application: put it in your supervision tree.

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    Malla.Cluster,     # only if you connect nodes with DNS (see below)
    {MyApp.Orders, []} # your services
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

The `:malla` application starts its own supervision tree (node registry, process groups, the node-wide store) when your application depends on it. It does not start your services, nor `Malla.Cluster`.

Configure the release in `config/runtime.exs`, which is read at boot, so the same release can run in several environments:

```elixir
import Config

config :malla,
  connect: [System.get_env("CLUSTER_NODE", "myapp@myapp-headless.default.svc.cluster.local")],
  remote_timeout: String.to_integer(System.get_env("REMOTE_TIMEOUT_MS", "15000"))

config :my_app, MyApp.Orders, otp_app_setting: [url: System.fetch_env!("ORDERS_URL")]
```

(`MyApp.Orders` here has `use Malla.Service, otp_app: :my_app`: its configuration is read from that application environment, see [Configuration](07-configuration.md).)

Two settings are **compile-time**: `config :malla, log_min_level:` is read when your modules are compiled, so it belongs in `config/prod.exs` (or `config.exs`), not in `runtime.exs`. See [Configuration](07-configuration.md).

### The Elixir compiler must be in the release

Malla compiles modules **at runtime**:

- **Dispatch modules** (`MyService.MallaDispatch`) are recompiled by Malla whenever the plugins of a running service change: `add_plugin/3`, `del_plugin/2`, `reconfigure/2` with `plugins:`, and `start_link/1` with `plugins:`. It uses `Module.create/3`, and `:beam_lib` and `:erl_prettypr` (from `syntax_tools`, which Malla lists in its applications).
- **Virtual (proxy) modules** are created by `Malla.Node` with `Module.create/3` when it discovers a service of another node for which this node has no module, and the stub modules of the `:precompile` setting are created at application start in the same way.

`Module.create/3` needs the Elixir compiler and the Erlang compiler application at runtime. A standard Mix release includes `elixir` and its dependencies, so it works as it is. Be careful with anything that removes them: a hand-made release, a release stripped of applications, or an escript or image that copies only your own `.beam` files. If the compiler is missing, those operations fail at runtime (a virtual module is never created, and changing plugins returns an error), not at build time.

## Node names and the cookie

Nodes must have long names and a shared cookie. In a release both are set with the usual release variables:

```sh
RELEASE_DISTRIBUTION=name
RELEASE_NODE=myapp@10.1.2.3          # name@ip, or name@fully.qualified.host
RELEASE_COOKIE=<a long random secret>
```

The name matters for `Malla.Cluster`: it connects to nodes called `name@ip`, so every node of the cluster must be named `<name>@<its own ip>`, with the same `<name>` that you put in `config :malla, connect:`. In Kubernetes, build it from the pod IP (for instance in `rel/env.sh.eex`: `export RELEASE_NODE=myapp@$POD_IP`, with `POD_IP` from the downward API: `fieldRef: status.podIP`).

**The cookie is the security boundary** of the cluster: any node that connects can run any code on the others. Keep it in a secret, not in the image or the repository, and keep the Erlang distribution ports reachable only from the other nodes. See [Cluster Setup](08-distribution/01-cluster-setup.md). Erlang also supports TLS for the distribution channel; that is configured in the VM, outside Malla, and is not covered here.

## Connecting the nodes

With `Malla.Cluster` in your tree and a `:connect` entry, nodes find each other through DNS:

```elixir
config :malla, connect: ["myapp@myapp-headless.default.svc.cluster.local"]
```

For a Kubernetes *headless* Service (`clusterIP: None`), the DNS name resolves to the IPs of the ready pods, and Malla connects to `myapp@<ip>` for each. The check repeats every 5 seconds, so pods that start later are found. If your nodes are not Kubernetes pods, any other way of connecting nodes works too (see [Cluster Setup](08-distribution/01-cluster-setup.md)).

Needed ports: EPMD (4369) and the distribution ports of the nodes. By default the VM picks a port at random; to open a fixed range, pass the standard Erlang kernel options (`inet_dist_listen_min` and `inet_dist_listen_max`), for example through `ELIXIR_ERL_OPTIONS` or `rel/vm.args.eex`.

Services declared with `global: true` are announced to the cluster. The nodes then call each other with `Malla.remote/4` (see [Remote Calls](08-distribution/03-remote-calls.md)).

## Kubernetes: probes and graceful shutdown

`Malla.Plugins.Httpd.Lifecycle` serves the probe and shutdown endpoints from a small HTTP server (see [HTTP Admin Server](11-http-admin.md)):

| Endpoint | Use | What it checks |
| :--- | :--- | :--- |
| `GET /is_live` | `livenessProbe` | `Malla.Service.is_live?/1` for every service of the node: `false` only for a service that is `:failed` (or not running) |
| `GET /is_ready` | `readinessProbe` | `Malla.Service.is_ready?/1` for every service: `:running`, and every plugin's `service_is_ready?/0` answered `:cont` |
| `GET /stop` | `preStop` hook | drains every service of the node, in `:priority` order |

```elixir
defmodule MyApp.Admin do
  use Malla.Service,
    plugins: [Malla.Plugins.Httpd.Lifecycle],
    # Drained last, so the HTTP server keeps answering while the others drain
    priority: 1000,
    malla_httpd: [port: 8080]
end
```

and in the container spec:

```yaml
containers:
  - name: myapp
    ports:
      - containerPort: 8080
        name: admin
    livenessProbe:
      httpGet: { path: /is_live, port: admin }
      periodSeconds: 10
      failureThreshold: 6
    readinessProbe:
      httpGet: { path: /is_ready, port: admin }
      periodSeconds: 5
    lifecycle:
      preStop:
        httpGet: { path: /stop, port: admin }
terminationGracePeriodSeconds: 60
```

Points to know:

- **The admin port has no authentication and listens on all interfaces.** The probes are made by the kubelet to the pod IP: do not put that port in a Service, an Ingress or a load balancer. Restrict it with a NetworkPolicy.
- **`/stop` drains; it does not stop anything.** It calls `httpd_lifecycle_drain_start/0`, then `Malla.Service.drain_all_local/0` until every service reports drained, then `httpd_lifecycle_drain/0`. It retries once per second, ten times at most, so the request can last about 10 seconds or more; set `terminationGracePeriodSeconds` above that, plus the time that Malla needs to stop the node. Kubernetes sends `SIGTERM` after the hook returns; the VM then shuts down the supervision tree, and each service stops its plugins (`plugin_stop/2`, then the children).
- **Take the node out of the calls while it drains.** Other Malla nodes route calls to any service whose status is `:running`; `is_ready?/1` is not consulted. In `httpd_lifecycle_drain_start/0`, pause the services so that they leave discovery: a paused service keeps its plugins (and the HTTP server) running, but it is no longer offered to other nodes.

```elixir
defmodule MyApp.Admin do
  use Malla.Service,
    plugins: [Malla.Plugins.Httpd.Lifecycle],
    priority: 1000,
    malla_httpd: [port: 8080]

  defcb httpd_lifecycle_drain_start() do
    # The services of this node that other nodes call (MyApp.Admin is not one of them)
    for service <- [MyApp.Orders, MyApp.Billing] do
      Malla.Service.set_admin_status(service, :pause, :draining)
    end

    :cont
  end
end
```

`MyApp.Admin` itself is not paused, so it keeps answering `/stop`. A paused service answers `false` to `is_ready?/1`, so `/is_ready` returns `500` once one of them is paused, which also takes the pod out of the Kubernetes Service endpoints.

- **Give each service the drain it needs.** Implement `service_drain/0` in the plugins that hold in-flight work (return `:cont` when done, `false` to be asked again), as in [Plugin Development](13-plugin-development.md).
- **A `:failed` service is reported as not live**: the liveness probe fails and Kubernetes restarts the pod. The service itself retries every 5 seconds, so allow `failureThreshold × periodSeconds` to be longer than your normal recovery.

## Rolling upgrades

During a rolling upgrade old and new versions of a service run at the same time, and Malla routes between them without looking at the version:

- `vsn` (the option of `use Malla.Service`) is **only metadata**. It is shown in the service information (`Malla.Service.get_service_info/2`, `Malla.Node.get_instances/1`), and Malla does not use it to check compatibility, or to choose or exclude nodes. It does not prevent mixed versions from calling each other.
- `Malla.Node.get_nodes/1` has the local node first and shuffles the others; a call goes to the first node that answers. During the upgrade a caller therefore reaches old and new nodes.
- Design the callbacks of a service so that the version before and the version after can both serve them: add new callbacks and new optional arguments before you remove old ones, and remove them in a later release. A `defcb` is identified by name and arity, so a new arity is a new callback.
- You can read the versions: `Malla.Node.get_instances(MyService)` returns each node's information with its `:vsn`. A caller that must reach only some of them can pick the nodes itself and pass them in the `:nodes` option of `Malla.Node.call_cb/4`.
- A node on an older Malla that answers `:service_not_available` (without the `malla_` prefix) is understood by newer nodes, so failover works while the cluster is upgraded node by node.
- New pods should not receive calls until they are ready: the service is offered to other nodes as soon as it is `:running`. If a service needs warming, start it paused (`use Malla.Service, paused: true`) and activate it with `set_admin_status(:active)` when ready.
- Runtime-built chains (plugins added with `add_plugin/3`) are not part of the new release: they live only in the VM that built them.

## Monitoring

- The default tracer emits `:telemetry` events (`[:malla, :tracer, :starts]`, `[:malla, :tracer, :stops]`) and `Malla.metric/4` emits yours; `Malla.Request` emits `[:malla, :request, :out]` and `[:malla, :request, :in]`. Attach a reporter of your choice (for Prometheus, OpenTelemetry, ...) to them.
- Real distributed tracing needs a tracer plugin; see [Tracing](09-observability/01-tracing.md).
- Logs go through `Logger`; `silent: true` suppresses a service's own start/stop/reconfiguration messages below `warning`.

## Next Steps

- [Cluster Setup](08-distribution/01-cluster-setup.md) - connecting nodes.
- [HTTP Admin Server](11-http-admin.md) - the endpoints in detail.
- [Lifecycle](06-lifecycle.md) - statuses, readiness and drain.
- [Troubleshooting](14-troubleshooting.md) - when something does not behave as expected.
