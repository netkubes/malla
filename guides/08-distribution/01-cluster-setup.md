# Cluster Setup

For Malla services to be distributed, the underlying Erlang nodes must be connected to form a cluster. This guide explains how to connect nodes and provides recommendations for production deployments.

Malla can work with any method of connecting Erlang nodes, as long as each node can "see" the others. The `Malla.Cluster` module provides utilities to simplify this process, especially in containerized environments like Kubernetes.

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
-   **Long names (`--name`)**: Use for production deployments with Fully Qualified Domain Names (FQDNs) (e.g., `mynode@example.com`).

## Using Malla.Cluster for Automatic Connection

The `Malla.Cluster` module provides helpers for discovering and connecting to nodes using DNS, which is a common pattern in orchestrated environments.

You can configure Malla to automatically connect to nodes based on a hostname.

```elixir
# In config/runtime.exs
config :malla, :connect, System.get_env("CLUSTER_DNS_NAME") || "malla.local"
```

The `Malla.Cluster` server will periodically check this configuration and attempt to connect to nodes found via DNS lookups on the given hostname.

You can also trigger connection manually using `Malla.Cluster.connect/1`

```elixir
# Connect to nodes discovered via a DNS A record lookup
Malla.Cluster.connect("malla-service.default.svc.cluster.local")

# Connect using DNS SRV records, which provide both hostnames and ports
Malla.Cluster.connect("_malla._tcp.example.com")
```

In the future, we will provide a tool capable of automating the distrbution of nodes and services in a Kubernetes environment.

## Next Steps

- [Service Discovery](02-service-discovery.md) - Learn how services find each other once the cluster is formed.
- [Remote Calls](03-remote-calls.md) - See how to call functions on services running on other nodes.
