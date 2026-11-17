# Quick Start

This guide walks you through creating your first Malla service, calling it locally, and calling it from a second Erlang node.

## Prerequisites

- Elixir 1.17 or later (`elixir: "~> 1.17"` in Malla's `mix.exs`), with a version of Erlang/OTP that your Elixir release supports.
- For the distributed part, a machine where Erlang nodes can reach each other on `127.0.0.1` (the Erlang port mapper daemon, `epmd`, is started by `iex --name`).

## Adding Malla to Your Project

Add `malla` to your list of dependencies in `mix.exs`. Check [hex.pm/packages/malla](https://hex.pm/packages/malla) for the latest version:

```elixir
def deps do
  [
    {:malla, "~> 0.1"}
  ]
end
```

Then run `mix deps.get` to install the dependency.

## Creating Your First Service

Create a simple service module in your project:

```elixir
defmodule MyService do
  use Malla.Service,
    global: true

  defcb fun1(a) do
    {:ok, %{you_said: a, node: node()}}
  end
end
```

## Running Locally

Start an IEx session:

```bash
iex -S mix
```

Inside IEx, start your service and call its function:

```elixir
iex> MyService.start_link()
{:ok, #PID<0.123.0>}

iex> MyService.fun1("hello")
{:ok, %{you_said: "hello", node: :nonode@nohost}}
```

## Testing Distributed Behavior

Now let's see Malla's distributed features in action. We will use three terminals: two nodes of this same project, and a third node of a different project that does not contain `MyService`.

### Start the First Node

Open a terminal in your project and start a node named `first`:

```bash
iex --name first@127.0.0.1 --cookie malla -S mix
```

In the IEx session, start your service:

```elixir
iex(first@127.0.0.1)> MyService.start_link()
{:ok, #PID<0.123.0>}
```

### Start a Second Node of the Same Project

Open a second terminal in the same project and start a node named `second`:

```bash
iex --name second@127.0.0.1 --cookie malla -S mix
```

Connect to the first node:

```elixir
iex(second@127.0.0.1)> Node.connect(:"first@127.0.0.1")
true

iex(second@127.0.0.1)> Node.list()
[:"first@127.0.0.1"]
```

Here the module `MyService` exists, but the service is **not started** on this node. Calling `MyService.fun1("x")` directly would simply run the code locally on `second`. To call the service wherever it runs, use `Malla.remote/4` (or the `Malla.call` macro). Both look for the nodes that are *running* the service and call it there:

```elixir
iex(second@127.0.0.1)> Malla.remote(MyService, :fun1, ["hello from second node"])
{:ok, %{you_said: "hello from second node", node: :"first@127.0.0.1"}}

# the macro form needs `require Malla`
iex(second@127.0.0.1)> require Malla
Malla

iex(second@127.0.0.1)> Malla.call MyService.fun1("hello again")
{:ok, %{you_said: "hello again", node: :"first@127.0.0.1"}}
```

The `node` value in the answer shows that the function ran on the first node.

### Call the Service from a Node That Does Not Have the Module

Create a second, empty project that only depends on Malla (it does not define `MyService`):

```bash
mix new client
cd client
# add {:malla, "~> 0.1"} to deps in mix.exs, then:
mix deps.get
iex --name third@127.0.0.1 --cookie malla -S mix
```

Connect to the first node (the node you started in the first terminal is still running `MyService`):

```elixir
iex(third@127.0.0.1)> Node.connect(:"first@127.0.0.1")
true

iex(third@127.0.0.1)> MyService.fun1("hello from a node without the module")
{:ok, %{you_said: "hello from a node without the module", node: :"first@127.0.0.1"}}
```

`MyService` does not exist in this project. When the third node connects, `Malla.Node` discovers the service running on the first node and generates a *virtual module* named `MyService` with a proxy function for each callback of the service, so `MyService.fun1/1` is routed to the first node. If you call it in the very first moments after connecting, before the service has been discovered, you get `UndefinedFunctionError`; try again.

Virtual modules contain only callbacks defined with `defcb`. A function defined with plain `def` in the service is not part of the virtual module; call it with `Malla.remote/4`. See [Remote Calls](08-distribution/03-remote-calls.md).

## What Just Happened?

1.  You defined a service with `use Malla.Service, global: true`.
2.  The `global: true` option made the service announce itself to the nodes of the cluster, through an Erlang `:pg` process group.
3.  When you called the service from another node, Malla:
    - Looked up the nodes that run the service (`Malla.Node.get_nodes/1`).
    - Called a node that runs it, with Erlang's `:erpc`.
    - Returned the result to you.
4.  On a node without the module, Malla generated a local proxy module with the name of the service, so that callbacks can be called as if it were local.

## Next Steps

- [Services](03-services.md) - Understand service options and the service lifecycle.
- [Distribution](08-distribution/01-cluster-setup.md) - Learn more about distributed features.
- [Configuration](07-configuration.md) - Learn how to configure your services.
