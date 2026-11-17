# Testing Malla Services

This guide shows how to test services and plugins with ExUnit: starting a service, calling its callbacks, testing a plugin on its own, changing plugins at runtime, testing across nodes, and keeping the logs quiet. All the examples have been run against Malla.

## Things that shape your tests

- **A running service is a named process and a named ETS table**, both named after the service module. Two tests cannot run the same service at the same time, so tests that start a service must be `async: false`, or use a different service module each.
- **A service has a global identity**: the dispatch module (`MyService.MallaDispatch`) is a module of the VM. If a test changes the plugins of a service (`start_link(plugins: ...)`, `add_plugin/3`, `del_plugin/2`), the rebuilt chain, and the configuration at that moment, stay loaded after the service stops, and the next test that starts the same module gets them. See "Changing plugins" below.
- **`start_link/1` returns before the plugins are started.** The service process starts them right after. Ask the service something that it answers after that (`Malla.Service.get_service_info/2`) before you check anything that depends on the plugins.

## Starting a service

Use `start_supervised/2`: ExUnit stops the service at the end of the test. The child spec of a service passes the options as the start options.

```elixir
defmodule MyApp.GreeterTest do
  use ExUnit.Case, async: false

  defmodule Greeter do
    use Malla.Service, silent: true, greeting: "Hello"

    defcb greet(name) do
      {:ok, "#{get_in(get_config(), [:greeting])}, #{name}"}
    end
  end

  test "greets with the configured greeting" do
    start_supervised!({Greeter, greeting: "Hi"})

    # Returns after the first status check, so the service is :running
    assert {:ok, %{running_status: :running}} = Malla.Service.get_service_info(Greeter)

    assert {:ok, "Hi, Ann"} = Greeter.greet("Ann")
  end
end
```

`start_supervised/2` returns `{:error, reason}` when the service cannot start. For example, a runtime option that is only allowed in the `use` (`:vsn`, `:global`, ...) gives `{:error, {{:key_not_allowed_in_service_start, :vsn}, child_spec}}`:

```elixir
assert {:error, {{:key_not_allowed_in_service_start, :vsn}, _child_spec}} =
         start_supervised({Greeter, vsn: "2"})
```

With a bare `Greeter.start_link(vsn: "2")` the test process (which is linked) would receive an exit signal instead.

### Waiting for a status

Statuses change inside the service process. To wait for one, poll `get_status/0`, or use `get_service_info/2` as a barrier (the service answers it after anything it had already queued for itself):

```elixir
defp wait_for_status(service, status, tries \\ 50) do
  cond do
    service.get_status() == status -> :ok
    tries == 0 -> flunk("#{inspect(service)} is #{inspect(service.get_status())}, not #{status}")
    true -> Process.sleep(20); wait_for_status(service, status, tries - 1)
  end
end
```

`set_admin_status/2` is synchronous: when it returns, the status (`:paused`, `:running`, `:stopped`) is already set.

## The service ID in the test process

Callbacks set the service ID themselves, so calling `Greeter.greet/1` works. A plain function of a service that uses tracer macros (`span`), `req`, `Malla.metric/4` or `Malla.get_service_id!/0` needs the service ID in the process that calls it. Set it in the test:

```elixir
setup do
  Malla.put_service_id(Greeter)
  :ok
end
```

The process dictionary is per process, so there is nothing to clean up. You can also call a function with the ID set only for the duration of the call:

```elixir
Malla.local(Greeter, :plain_function, [1, 2])
```

## Calling callbacks

Call the callback on the service module to run the **whole chain**:

```elixir
Greeter.greet("Ann")
```

A plugin's `defcb` is also a normal public function on the plugin module. You can call it directly to test that plugin alone, with no chain (it must not need the service ID, or you must set it):

```elixir
assert {:cont, "ANN"} = MyApp.UpcasePlugin.process("ann")
```

To see what the chain is, ask the service:

```elixir
MyService.service().plugin_chain
# [MyService, MyApp.UpcasePlugin, Malla.Plugins.Base]

Malla.Service.get_callbacks(MyService, :process)
# [{{:process, 1}, [{MyApp.UpcasePlugin, :process}]}]
```

A callback whose last implementation returns `:cont` or `{:cont, ...}` returns that raw value to the caller. Your tests should cover that case with a clause at the bottom of the chain that returns a value (see [Callbacks](05-callbacks.md)).

## Testing a plugin with a minimal service

To test a plugin, define the smallest service that uses it, inside the test module:

```elixir
defmodule MyApp.UpcasePluginTest do
  use ExUnit.Case, async: false

  defmodule UpcasePlugin do
    use Malla.Plugin

    defcb process(text) when is_binary(text), do: {:cont, String.upcase(text)}
    defcb process(_other), do: :cont
  end

  defmodule Echo do
    use Malla.Plugin, plugin_deps: []

    # The bottom of the chain: it returns a final value
    defcb process(text), do: {:ok, text}
  end

  defmodule Svc do
    use Malla.Service, plugins: [UpcasePlugin, Echo], silent: true
  end

  test "upcases text before the rest of the chain sees it" do
    start_supervised!(Svc)

    assert {:ok, "HELLO"} = Svc.process("hello")
    assert {:ok, 5} = Svc.process(5)
  end

  test "the plugin comes first in the chain" do
    assert [Svc, UpcasePlugin, Echo, Malla.Plugins.Base] = Svc.service().plugin_chain
  end
end
```

`Svc.service()` is available without starting the service: the chain is resolved at compile time.

Lifecycle callbacks (`plugin_config/2`, `plugin_start/2`, ...) are plain functions: you can test them directly (`MyPlugin.plugin_config(MyService, config)`) or through the service. To test them through the service, record what they do in the service table (`Malla.Service.put/3`), or send a message to the test process, and assert on it after starting the service.

```elixir
defmodule Recorder do
  use Malla.Plugin

  @impl true
  def plugin_start(srv_id, _config) do
    Malla.Service.put(srv_id, :started, true)
    :ok
  end
end
```

### Configuration

```elixir
start_supervised!({Svc, my_plugin: [timeout: 10]})
{:ok, _} = Malla.Service.get_service_info(Svc)

assert [my_plugin: [timeout: 10]] = Svc.get_config()

assert :ok = Svc.reconfigure(my_plugin: [retries: 5])
assert [timeout: 10, retries: 5] = Svc.get_config()[:my_plugin]

assert {:error, {:key_not_allowed_in_service_start, :vsn}} = Svc.reconfigure(vsn: "2")
```

## Changing plugins

Test a runtime plugin change by starting the service with the plugins you want, then calling `add_plugin/3`, `del_plugin/2` or `reconfigure/2`:

```elixir
test "a plugin can be removed from a running service" do
  start_supervised!({Svc, plugins: [UpcasePlugin, Echo]})
  assert {:ok, "HELLO"} = Svc.process("hello")

  assert :ok = Malla.Service.del_plugin(Svc, UpcasePlugin)

  # The dispatch module is already rebuilt when del_plugin/2 returns
  assert {:ok, "hello"} = Svc.process("hello")
end
```

Because the rebuilt chain survives the end of the test, **start the service with an explicit `plugins:` in every test** that changes plugins: it replaces whatever a previous test left. Or use a separate service module for each such test.

`add_plugin/3` and `del_plugin/2` return when the chain has been rebuilt; the plugin is started (or stopped) right after, in the service process. Use `Malla.Service.get_service_info/2` as a barrier before checking `plugin_start/2` or `plugin_stop/2` effects. A `reconfigure/2` with `plugins:` starts the new plugins up to 5 seconds later; test those with an explicit wait, or use `add_plugin/3`.

## Testing request handling

`Malla.Request.request/4` needs a service ID in the calling process, and `Malla.Plugins.Request` in the called service. With `direct: true` the call does not go through RPC:

```elixir
defmodule MyApp.RequestTest do
  use ExUnit.Case, async: false

  defmodule Users do
    use Malla.Service, plugins: [Malla.Plugins.Request], silent: true

    def get(1), do: {:ok, %{name: "Ann"}}
    def get(_), do: {:error, :not_found}
  end

  test "normalizes responses" do
    start_supervised!(Users)
    Malla.put_service_id(Users)

    assert {:ok, %{name: "Ann"}} = Malla.Request.request(Users, :get, [1], direct: true)

    assert {:error, %Malla.Status{status: "not_found", code: 404}} =
             Malla.Request.request(Users, :get, [2], direct: true)
  end
end
```

## Testing across nodes

To test discovery and remote calls you need real nodes. Erlang's `:peer` module starts them, and it is enough for the whole test: no containers are needed.

Distribution needs the test node to be alive and `epmd` to be running. Put that in a case template:

```elixir
defmodule MyApp.ClusterCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import MyApp.ClusterCase
    end
  end

  setup_all do
    # Distributed Erlang needs epmd and a named test node
    System.cmd("epmd", ["-daemon"])

    if not Node.alive?() do
      {:ok, _} = Node.start(:"test@127.0.0.1", :longnames)
    end

    Node.set_cookie(:test_cookie)
    :ok
  end

  @doc "Starts a peer node that has Malla running but none of your test modules."
  def start_peer(name) do
    paths = Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)

    {:ok, peer, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        args: [~c"-setcookie", ~c"test_cookie"] ++ paths,
        connection: :standard_io
      })

    {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:malla])
    {peer, node}
  end

  @doc "Compiles `source` here and loads its modules on `node` only."
  def load_on(node, source) do
    for {module, binary} <- Code.compile_string(source) do
      {:module, ^module} = :erpc.call(node, :code, :load_binary, [module, ~c"nofile", binary])
      # compiling defined it here too: unload it, so that only the peer has it
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end

  @doc "Waits until `node` sees the service."
  def wait_for_service(node, service, tries \\ 50) do
    cond do
      :erpc.call(node, Malla.Node, :get_nodes, [service]) != [] -> :ok
      tries == 0 -> flunk("service #{inspect(service)} not seen by #{node}")
      true -> Process.sleep(100); wait_for_service(node, service, tries - 1)
    end
  end
end
```

A test that runs a service on a peer and calls it from the test node:

```elixir
defmodule MyApp.ClusterTest do
  use MyApp.ClusterCase, async: false
  require Malla

  @service """
  defmodule MyApp.Echo do
    use Malla.Service, global: true, silent: true

    def whoami(), do: node()
    defcb echo(value), do: {:ok, value, node()}

    # Start the service on that node under a supervisor that does not die with the caller
    def start_detached() do
      {:ok, sup} = Supervisor.start_link([MyApp.Echo], strategy: :one_for_one)
      Process.unlink(sup)
      :ok
    end
  end
  """

  test "calls a service that runs on another node" do
    {peer, node} = start_peer(:echo_peer)
    load_on(node, @service)
    :ok = :erpc.call(node, MyApp.Echo, :start_detached, [])

    # This node has no MyApp.Echo module: wait for it to be discovered
    wait_for_service(node(), MyApp.Echo)

    assert {:ok, 1, ^node} = Malla.remote(MyApp.Echo, :echo, [1])
    assert ^node = Malla.remote(MyApp.Echo, :whoami, [])

    # The virtual module that Malla generated here has only callbacks
    assert {:ok, 2, ^node} = apply(MyApp.Echo, :echo, [2])
    assert_raise UndefinedFunctionError, fn -> apply(MyApp.Echo, :whoami, []) end

    :ok = :peer.stop(peer)
  end
end
```

Notes:

- The peer is started with your code paths (`-pa`), so it has Malla and your compiled modules. Modules defined **inside a test file** exist only in memory of the test node, so they are not on the peer: that is why this example compiles the service source and loads it on the peer with `:code.load_binary/3`. A service defined in `lib/` or in a compiled `test/support` directory (`elixirc_paths`) is already on the peer, and `start_detached/0` or a supervisor of your own can start it there.
- The service must not be linked to the process that starts it through `:erpc` (that process ends right after the call and takes the service with it). Start it under a supervisor that you unlink, as in `start_detached/0`.
- The test node has no `MyApp.Echo` module, so Malla generates a virtual module for it. If your test node has the module (it is in `lib/`), `MyApp.Echo.echo(2)` runs locally; use `Malla.remote/4` to reach the peer.
- Calls to a service that is not available retry five times, one second apart, by default. In tests that expect `{:error, :malla_service_not_available}` pass `sna_retries: 0`.
- To test failover, start the service on two peers and stop it on the first (`set_admin_status(:pause)` or `stop/0`): calls still reach the second.
- Malla's own `test/node_discovery_test.exs` fakes a remote service by announcing it by hand to `Malla.Node`, which uses internal messages that are not public API. Real peers, as above, are the more robust approach for your tests.
- `:peer.stop/1` stops the peer; use `start_link` as above so a failing test does not leave it running.

Add `epmd` to your CI image or start it before the tests (`epmd -daemon`).

## Keeping logs quiet

- Pass `silent: true` in `use Malla.Service` (or in the module that you define in the test). It suppresses the service's own messages about starting, status changes and reconfiguration (levels `debug`, `info` and `notice`). Warnings, such as a failed plugin start, are still logged.
- Set the Logger level in `test/test_helper.exs` or `config/test.exs`: `Logger.configure(level: :error)` or `config :logger, level: :warning`.
- Capture the logs you want to assert on with `ExUnit.CaptureLog.capture_log/1`.

## Next Steps

- [Plugin Development](13-plugin-development.md) - a complete plugin to test.
- [Troubleshooting](14-troubleshooting.md) - when a test does not behave as you expect.
