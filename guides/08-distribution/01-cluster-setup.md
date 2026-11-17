# Cluster Setup

For Malla services to be distributed, the underlying Erlang nodes must be connected to form a cluster. This guide explains how to connect nodes and provides recommendations for production deployments.

Malla can work with any method of connecting Erlang nodes, as long as each node can "see" the others. The `Malla.Cluster` module provides utilities to simplify this process, especially in containerized environments like Kubernetes, but you can use any other method, like the popular [libcluster](https://hex.pm/packages/libcluster) library.

## Security: the cookie is the trust boundary

Erlang distribution has no authorization beyond the cookie. **Any node that is connected to your cluster can run any function on any other node** (`:erpc.call/4`, `:rpc`, `Code.eval_string/1`, ...), and Malla's remote calls rely on that. Treat the cookie as a root credential: use a long random value, keep it out of source control, and only allow the distribution ports (EPMD, 4369, and the ports of the nodes) to be reached from the nodes of the cluster. Do not expose them to the internet or to untrusted pods.

## Basic Node Connection

### Prerequisites

All nodes in a cluster must:
-   **Share the same Erlang cookie**: This is a secret that authenticates nodes to each other.
-   **Be mutually reachable on the network**: Firewalls must allow traffic on the required ports.
-   **Have compatible Erlang/OTP versions**.

### Manual Connection

You can connect nodes manually for local development and testing.

First, start two nodes with the same cookie. The `--sname` flag gives the node a short name, suitable for local networks.

```bash
# Terminal 1
iex --sname node1 --cookie malla_secret -S mix

# Terminal 2
iex --sname node2 --cookie malla_secret -S mix
```

From the second node, connect to the first:

```elixir
# In node2's IEx session
iex(node2@hostname)> Node.connect(:"node1@hostname")
true

iex(node2@hostname)> Node.list()
[:"node1@hostname"]
```

Now, the two nodes are connected and can host distributed Malla services.

### Long Names vs. Short Names

-   **Short names (`--sname`)**: Use for local development (e.g., `mynode`). The node's full name becomes `mynode@hostname`.
-   **Long names (`--name`)**: Use for production deployments with Fully Qualified Domain Names or IP addresses (e.g., `mynode@example.com`, `mynode@10.1.2.3`). `Malla.Cluster` builds node names of the form `name@ip`, so it needs nodes started with `--name`.

## Using Malla.Cluster for Automatic Connection

`Malla.Cluster` connects to nodes discovered through DNS, a common pattern in orchestrated environments.

**Malla does not start `Malla.Cluster` for you.** The `:malla` application only starts its own processes; you must add `Malla.Cluster` to your application's supervision tree, otherwise `config :malla, connect: [...]` is never read.

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    Malla.Cluster,
    MyApp.MyService
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

```elixir
# config/runtime.exs
import Config

config :malla, connect: [System.get_env("CLUSTER_NODES", "myapp@myapp-headless.default.svc.cluster.local")]
```

Five seconds after it starts, and then every 5 seconds, the `Malla.Cluster` process reads the `:connect` setting of the `:malla` application and calls `Malla.Cluster.connect/1` with it. The value is a list of strings (a single string also works). Nodes that are already connected are skipped, so the call is cheap to repeat, and it keeps trying nodes that were not up yet.

### The two forms of an entry

Each entry has one of two forms:

- **`name@domain`**: Malla first looks up a *DNS SRV* record named `domain`. If it finds one, it uses the nodes it lists (see below) and ignores `name`. If it finds none, it looks up the *A records* of `domain` and tries to connect to `name@<ip>` for each address.
- **`domain`** (no `@`): Malla only does the *SRV* lookup. It does **not** fall back to A records. If you have no SRV record for the name, use the `name@domain` form.

For an SRV record, each target host name `host.rest-of-name` becomes a node named `host@<ip>`, where the IPs come from the A records of the target. The **port of the SRV record is ignored**: Erlang finds the distribution port of a node through EPMD, which has to be reachable on its usual port (4369).

```elixir
# A headless Kubernetes service: its A record lists the IP of each pod.
# Nodes must be named myapp@<pod-ip>
config :malla, connect: ["myapp@myapp-headless.default.svc.cluster.local"]

# An SRV record: node names and IPs come from the record
config :malla, connect: ["_epmd._tcp.myapp.example.com"]
```

You can also trigger the connection manually:

```elixir
Malla.Cluster.connect("myapp@myapp-headless.default.svc.cluster.local")
Malla.Cluster.connect(["myapp@host1.example.com", "myapp@host2.example.com"])
```

Every failed SRV lookup writes a `warning` to the log ("Error in resolve for ..."). With the `name@domain` form that goes straight to A records, you will see this warning on each round (every 5 seconds); it is expected.
## Next Steps

- [Service Discovery](02-service-discovery.md) - Learn how services find each other once the cluster is formed.
- [Remote Calls](03-remote-calls.md) - See how to call functions on services running on other nodes.
- [Deployment](../15-deployment.md) - Releases, node names and Kubernetes.
