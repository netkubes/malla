defmodule NodeDiscoveryTest do
  @moduledoc false
  # Proxy modules created by Malla.Node for services found in other nodes

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  # Announces a service as running in another process (as another node
  # would), and waits for Malla.Node to process it
  defp announce(srv_id, callbacks) do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    info = %{id: srv_id, pid: pid, meta: %{callbacks: callbacks}}
    GenServer.cast(Malla.Node, {:set_service_info, true, info})
    _ = Malla.Node.get_services()
    pid
  end

  defp forget(pid) do
    Process.exit(pid, :kill)
    _ = Malla.Node.get_services()
  end

  defp unload(module) do
    :code.delete(module)
    :code.purge(module)
  end

  test "a module of this node not loaded yet is not replaced", %{tmp_dir: dir} do
    # A global service whose code is in this node (in a .beam file), but
    # not loaded yet, as in interactive mode before its first use
    srv_id = NodeDiscoveryLocal

    # The service and its submodules
    modules =
      Code.compile_string("""
      defmodule NodeDiscoveryLocal do
        use Malla.Service, global: true
        defcb discovery_cb(arg), do: {:local, arg}
      end
      """)

    for {module, beam} <- modules do
      File.write!(Path.join(dir, "#{module}.beam"), beam)
      unload(module)
    end

    Code.prepend_path(dir)
    refute :erlang.module_loaded(srv_id)

    pid = announce(srv_id, discovery_cb: 1)

    assert :erlang.module_loaded(srv_id)
    refute function_exported?(srv_id, :__malla_node_callbacks, 0)
    assert function_exported?(srv_id, :__service__, 1)

    forget(pid)
    for {module, _} <- modules, do: unload(module)
    Code.delete_path(dir)
  end

  test "a service without code in this node gets a proxy module" do
    srv_id = NodeDiscoveryRemoteOnly
    pid = announce(srv_id, remote_cb: 1)

    assert function_exported?(srv_id, :__malla_node_callbacks, 0)
    assert apply(srv_id, :__malla_node_callbacks, []) == [remote_cb: 1]

    forget(pid)
    unload(srv_id)
  end
end
