# Quick Start

This guide will walk you through creating your first distributed Malla service.

## Prerequisites

- Elixir 1.17 or later
- Erlang/OTP 26 or later

## Adding Malla to Your Project

Add `malla` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:malla, ">= 0.0.0"}
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
    {:ok, %{you_said: a}}
  end
end
```

## Running Locally

You can start and interact with your service on a single node.

Start an IEx session:
```bash
iex -S mix
```

Inside IEx, start your service and call its function:
```elixir
iex> MyService.start_link()
{:ok, #PID<0.123.0>}

iex> MyService.fun1("hello")
{:ok, %{you_said: "hello"}}
```

## Testing Distributed Behavior

Now, let's see Malla's distributed features in action.

### Start the First Node

Open a terminal and start the first node named `first`:

```bash
iex --name first@127.0.0.1 --cookie malla -S mix
```

In the IEx session, start your service:

```elixir
iex(first@127.0.0.1)> MyService.start_link()
{:ok, #PID<0.123.0>}

iex(first@127.0.0.1)> Node.self()
:"first@127.0.0.1"
```

### Start the Second Node

Open a second terminal and start another node named `second`, but on an application 
not having module "MyService"

```bash
iex --name second@127.0.0.1 --cookie malla -S mix
```

In this second session, connect to the first node:

```elixir
iex(second@127.0.0.1)> Node.connect(:"first@127.0.0.1")
true

iex(second@127.0.0.1)> Node.list()
[:"first@127.0.0.1"]
```

### Call the Remote Service

From the second node, you can now call the service that is running on the first node, and Malla will handle the remote communication transparently:

```elixir
iex(second@127.0.0.1)> Malla.remote(MyService, :fun1, ["hello from second node"])
{:ok, %{you_said: "hello from second node"}}

# you can also use the helper macros
iex(second@127.0.0.1)> require Malla
Malla

iex(second@127.0.0.1)> Malla.call MyService.fun1("hellow again")
{:ok, %{you_said: "hello again"}}

# or use the virtual node feature 
# make sure you don't declare module `MyService` on this second node
iex(second@127.0.0.1)> MyService.fun1("funny")
{:ok, %{you_said: "funny"}}
```

The call is automatically routed to the first node where the service is running, and the result is returned to you.

## What Just Happened?

1.  You defined a service with `use Malla.Service, global: true`.
2.  The `global: true` option made the service announce itself to other nodes in the cluster.
3.  When you called `MyService.fun1/1` from the second node (at any of the versions), Malla:
    - Detected the service was not running locally.
    - Found the service running on the `first` node.
    - Routed the call automatically and transparently.
    - Returned the result as if it were a local call.

## Next Steps

- [Services](03-services.md) - Understand service options and the service lifecycle.
- [Distribution](08-distribution/01-cluster-setup.md) - Learn more about distributed features.
- [Configuration](07-configuration.md) - Learn how to configure your services.
