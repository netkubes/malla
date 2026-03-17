defmodule Service2.Test do
  use ExUnit.Case, async: false

  alias Malla.Service.Server

  describe "callback chain compilation" do
    test "service defines correct callback structure" do
      callbacks = get_callbacks(:cb_only_service)
      assert [{{:cb_only_service, 0}, [{Service2, :cb_only_service_malla_service}]}] = callbacks
      callbacks = get_callbacks(:cb_only_plugin1)
      assert [{{:cb_only_plugin1, 0}, [{Plugin2_1, :cb_only_plugin1}]}] = callbacks
      callbacks = get_callbacks(:cb_only_plugin2)
      assert [{{:cb_only_plugin2, 0}, [{Plugin2_2, :cb_only_plugin2}]}] = callbacks
      callbacks = get_callbacks(:cb_plug1_and_service)

      assert [
               {{:cb_plug1_and_service, 1},
                [
                  {Service2, :cb_plug1_and_service_malla_service},
                  {Plugin2_1, :cb_plug1_and_service}
                ]}
             ] = callbacks

      callbacks = get_callbacks(:cb_plug2_plug1_and_service)

      assert [
               {{:cb_plug2_plug1_and_service, 1},
                [
                  {Service2, :cb_plug2_plug1_and_service_malla_service},
                  {Plugin2_1, :cb_plug2_plug1_and_service},
                  {Plugin2_2, :cb_plug2_plug1_and_service}
                ]}
             ] = callbacks
    end
  end

  describe "callback execution" do
    test "callbacks defined only in their module work" do
      assert :only_service == Service2.cb_only_service()
      assert :only_plugin1 == Service2.cb_only_plugin1()
      assert :only_plugin2 == Service2.cb_only_plugin2()
      assert :srv == Service2.cb_plug1_and_service(:srv)
      assert {:plug1, :plug1} == Service2.cb_plug1_and_service(:plug1)
      assert {:plug1, :other} == Service2.cb_plug1_and_service(:other)
      assert :srv == Service2.cb_plug2_plug1_and_service(:srv)
      assert :plug1 == Service2.cb_plug2_plug1_and_service(:plug1)
      assert {:plug2, {:plug1, :other1}} == Service2.cb_plug2_plug1_and_service({:plug1, :other1})
      assert {:plug2, :other2} == Service2.cb_plug2_plug1_and_service(:other2)
    end
  end

  describe "service lifecycle" do
    setup do
      on_exit(fn ->
        if Process.whereis(Service2) do
          Service2.stop()
          Process.sleep(1000)
        end
      end)
    end

    test "service starts and registers correctly" do
      clear_chains()
      {:ok, pid} = Service2.start_link(plugin2_2: %{a: 2}, z: 1)
      # config was passed to service_config (before plugin_config runs)
      sc_config = Malla.Config.get(Service2, :service_config_config)
      assert is_list(sc_config)
      assert Keyword.has_key?(sc_config, :plugin2_1)

      # check config order was correct
      assert [Service2, Plugin2_1, Plugin2_2] == Malla.Config.get(Service2, :config_chain)
      # check config content (a from service, b from start_link, plugin1_added from Plugin2_1)
      config = Service2.get_config()
      # also available via the helper
      assert config == Malla.Service.get_config(Service2)

      # plugins updated the config
      assert %{a: 1, b: 2} == Keyword.get(config, :plugin2_1)
      assert %{a: 2, b: 3} == Keyword.get(config, :plugin2_2)
      assert %{a: 3, b: 4} == Keyword.get(config, :service2)
      # z was passed at start_link and deep-merged into config
      assert 1 == Keyword.get(config, :z)

      assert ^pid = Process.whereis(Service2)
      {:error, {:already_started, ^pid}} = Service2.start_link()
      Process.sleep(100)
      # check start order
      assert [Plugin2_2, Plugin2_1, Service2] == Malla.Service.get(Service2, :start_chain)
      assert :running == Service2.get_status()
      info = Server.get_all_local() |> Enum.filter(&(Map.get(&1, :class) == :test))
      assert [%{id: Service2, class: :test, hash: _hash, pid: ^pid}] = info
      assert Enum.member?(Server.get_all_global_pids(), pid)
      child = Process.whereis(Plugin2_1.Child)
      assert true == Process.alive?(child)
      Service2.stop()
      Process.sleep(100)
      # check stop order
      assert [Service2, Plugin2_1, Plugin2_2] = Malla.Config.get(Service2, :stop_chain)
    end

    test "plugin supervisor restarts when killed" do
      clear_chains()
      {:ok, pid} = Service2.start_link(b: 2)
      Process.sleep(100)
      child = Process.whereis(Plugin2_1.Child)
      assert true == Process.alive?(child)

      plug1_sup = get_plugin_sup(Plugin2_1)
      assert is_pid(plug1_sup)

      Process.exit(plug1_sup, :kill)
      Process.sleep(100)
      assert :failed == Service2.get_status()

      # force re-check of children
      send(pid, :timed_check_status)
      Process.sleep(100)
      assert :running == Service2.get_status()
      assert false == Process.alive?(child)
      child2 = Process.whereis(Plugin2_1.Child)
      assert true == Process.alive?(child2)

      assert :ok == Service2.set_admin_status(:pause, :my_test)
      Process.sleep(100)
      assert :paused == Service2.get_status()
      assert true == Process.alive?(child2)

      assert :ok = Service2.set_admin_status(:inactive, :my_test)
      Process.sleep(100)
      assert :stopped == Service2.get_status()
      assert false == Process.alive?(child2)

      assert :ok = Service2.set_admin_status(:active, :my_test)
      Process.sleep(100)
      assert :running == Service2.get_status()
      assert false == Process.alive?(child2)
      child3 = Process.whereis(Plugin2_1.Child)
      assert true == Process.alive?(child3)

      Service2.stop()
      Process.sleep(100)

      assert [] ==
               Server.get_all_local()
               |> Enum.filter(&(Map.get(&1, :class) == :test))

      refute Enum.member?(Server.get_all_global_pids(), pid)
    end
  end

  describe "plugin management" do
    setup do
      on_exit(fn ->
        if Process.whereis(Service2) do
          Service2.stop()
          Process.sleep(1000)
        end
      end)
    end

    test "service reconfiguration works correctly" do
      clear_chains()
      {:ok, _pid} = Service2.start_link([])
      Process.sleep(100)

      # Verify initial config
      config = Service2.get_config()
      assert %{a: 1, b: 2} == Keyword.get(config, :plugin2_1)
      assert nil == Keyword.get(config, :plugin2_2)
      assert %{a: 3, b: 4} == Keyword.get(config, :service2)

      # Clear chains to track only reconfiguration calls
      clear_chains()

      # Reconfigure with new values for plugin2_1 and plugin2_2
      :ok = Service2.reconfigure(plugin2_1: %{a: 10}, plugin2_2: %{a: 20})
      Process.sleep(100)

      # Verify plugin_config_merge call order (top-down: Service2 → Plugin2_1 → Plugin2_2)
      assert [Service2, Plugin2_1, Plugin2_2] == Malla.Config.get(Service2, :config_merge_chain)

      # Verify plugin_updated call order (bottom-up: Plugin2_2 → Plugin2_1 → Service2)
      assert [Plugin2_2, Plugin2_1, Service2] == Malla.Config.get(Service2, :updated_chain)

      # Verify new config values (plugin_config callbacks add b: a+1)
      config = Service2.get_config()
      assert %{a: 10, b: 11} == Keyword.get(config, :plugin2_1)
      assert %{a: 20, b: 21} == Keyword.get(config, :plugin2_2)
      assert %{a: 3, b: 4} == Keyword.get(config, :service2)

      # Service should still be running
      assert :running == Service2.get_status()

      Service2.stop()
      Process.sleep(100)
    end

    test "plugin triggers restart when its config changes" do
      clear_chains()
      {:ok, _pid} = Service2.start_link([])
      Process.sleep(100)

      # Get initial plugin supervisor PID
      initial_sup_pid = get_plugin_sup(Plugin2_1)
      assert is_pid(initial_sup_pid)

      # Get initial child PID
      initial_child_pid = Process.whereis(Plugin2_1.Child)
      assert is_pid(initial_child_pid)

      # Reconfigure plugin2_2 only (should NOT trigger restart)
      :ok = Service2.reconfigure(plugin2_2: %{a: 99})
      Process.sleep(100)

      # Supervisor and child PIDs should be unchanged
      assert ^initial_sup_pid = get_plugin_sup(Plugin2_1)
      assert ^initial_child_pid = Process.whereis(Plugin2_1.Child)
      assert :running == Service2.get_status()

      # Now reconfigure plugin2_1 (SHOULD trigger restart)
      :ok = Service2.reconfigure(plugin2_1: %{a: 50})
      Process.sleep(200)

      # Supervisor PID should have changed after restart
      new_sup_pid = get_plugin_sup(Plugin2_1)
      assert is_pid(new_sup_pid)
      assert new_sup_pid != initial_sup_pid

      # Child should have been restarted with new PID
      new_child_pid = Process.whereis(Plugin2_1.Child)
      assert is_pid(new_child_pid)
      assert new_child_pid != initial_child_pid

      # Service should still be running
      assert :running == Service2.get_status()

      # Verify new config was applied
      config = Service2.get_config()
      assert %{a: 50, b: 51} == Keyword.get(config, :plugin2_1)

      Service2.stop()
      Process.sleep(100)
    end

    test "plugins can be added and removed dynamically" do
      # Clear chains before starting
      clear_chains()

      {:ok, _pid} = Service2.start_link([])
      Process.sleep(100)

      config = Service2.get_config()
      assert %{a: 1, b: 2} == Keyword.get(config, :plugin2_1)
      # initial start - no config for plugin2_2
      assert nil == Keyword.get(config, :plugin2_2)
      assert %{a: 3, b: 4} == Keyword.get(config, :service2)

      plug1_sup = get_plugin_sup(Plugin2_1)
      assert is_pid(plug1_sup)

      # If we delete Plugin2_1, Plugin2_2 will be deleted too, since it
      # was a dependency only on Plugin2_1
      :ok = Malla.Service.del_plugin(Service2, Plugin2_1)
      Process.sleep(100)
      assert nil == get_plugin_sup(Plugin2_1)

      # Check stop order after removing plugins
      # Only the removed plugins are stopped, not Service2 (which is still running)
      # Note: stop_chain is stored in Config, not Service.get
      assert [Plugin2_2, Plugin2_1] == Malla.Config.get(Service2, :stop_chain)

      %{plugin_chain: chain} = Service2.service()
      assert [Service2, Malla.Plugins.Base] == chain

      # Verify Plugin2_1 callbacks are removed from the chain
      callbacks = get_callbacks(:cb_only_plugin1)
      assert [] == callbacks

      callbacks = get_callbacks(:cb_plug1_and_service)
      # Should only have Service2 implementation, not Plugin2_1
      assert [{{:cb_plug1_and_service, 1}, [{Service2, :cb_plug1_and_service_malla_service}]}] =
               callbacks

      # Verify Plugin2_2 callbacks are removed from the chain
      callbacks = get_callbacks(:cb_only_plugin2)
      assert [] == callbacks

      callbacks = get_callbacks(:cb_plug2_plug1_and_service)
      # Should only have Service2 implementation, not Plugin2_1 or Plugin2_2
      assert [
               {{:cb_plug2_plug1_and_service, 1},
                [{Service2, :cb_plug2_plug1_and_service_malla_service}]}
             ] = callbacks

      # Clear start_chain to track plugins being added back
      clear_chains()
      Malla.Service.put(Service2, :start_chain, [])

      # Add Plugin2_1 back (which will also add Plugin2_2 as a dependency)
      # This time we will provide a different config
      # IO.puts("ADD PLUGIN BACK")
      :ok = Malla.Service.add_plugin(Service2, Plugin2_1, config: [plugin2_2: %{a: 5}])
      # Wait for service to restart with new plugins
      Process.sleep(100)

      # Verify service is running
      assert :running == Service2.get_status()

      config = Service2.get_config()
      assert %{a: 1, b: 2} == Keyword.get(config, :plugin2_1)
      # this time we provided config for plugin2_2 via add_plugin
      assert %{a: 5, b: 6} == Keyword.get(config, :plugin2_2)
      assert %{a: 3, b: 4} == Keyword.get(config, :service2)

      # Check start order after adding plugins back (bottom-up: base plugins first)
      assert [Plugin2_2, Plugin2_1] == Malla.Service.get(Service2, :start_chain)

      new_plug1_sup = get_plugin_sup(Plugin2_1)
      assert is_pid(new_plug1_sup)

      # Verify plugin_chain is restored
      %{plugin_chain: chain} = Service2.service()
      assert [Service2, Plugin2_1, Plugin2_2, Malla.Plugins.Base] == chain

      # Verify Plugin2_1 callbacks are back in the chain
      callbacks = get_callbacks(:cb_only_plugin1)
      assert [{{:cb_only_plugin1, 0}, [{Plugin2_1, :cb_only_plugin1}]}] = callbacks

      callbacks = get_callbacks(:cb_plug1_and_service)

      assert [
               {{:cb_plug1_and_service, 1},
                [
                  {Service2, :cb_plug1_and_service_malla_service},
                  {Plugin2_1, :cb_plug1_and_service}
                ]}
             ] = callbacks

      # Verify Plugin2_2 callbacks are back in the chain
      callbacks = get_callbacks(:cb_only_plugin2)
      assert [{{:cb_only_plugin2, 0}, [{Plugin2_2, :cb_only_plugin2}]}] = callbacks

      callbacks = get_callbacks(:cb_plug2_plug1_and_service)

      assert [
               {{:cb_plug2_plug1_and_service, 1},
                [
                  {Service2, :cb_plug2_plug1_and_service_malla_service},
                  {Plugin2_1, :cb_plug2_plug1_and_service},
                  {Plugin2_2, :cb_plug2_plug1_and_service}
                ]}
             ] = callbacks

      # Clear stop_chain to track final stop
      Malla.Config.put(Service2, :stop_chain, [])

      Service2.stop()
      Process.sleep(100)

      # Check final stop order (top-down: service first, then plugins)
      assert [Service2, Plugin2_1, Plugin2_2] == Malla.Config.get(Service2, :stop_chain)
    end
  end

  defp clear_chains do
    Malla.Config.del(Service2, :config_chain)
    Malla.Config.del(Service2, :start_chain)
    Malla.Config.del(Service2, :stop_chain)
    Malla.Config.del(Service2, :config_merge_chain)
    Malla.Config.del(Service2, :updated_chain)
    Malla.Config.del(Service2, :service_config_config)
  end

  defp get_callbacks(plugin), do: Malla.Service.get_callbacks(Service2, plugin)
  defp get_plugin_sup(plugin), do: Malla.Service.get_plugin_sup(Service2, plugin)
end
