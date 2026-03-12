defmodule Malla.RuntimePluginsTest do
  @moduledoc false
  # Tests for runtime plugin specification at start_link.
  #
  # Validates that:
  # - Plugins can be specified at start_link time via the plugins: option
  # - Runtime plugins replace compile-time plugins entirely
  # - Plugin chain is correctly rebuilt with dependency resolution
  # - Callbacks dispatch through the new plugin chain
  # - Lifecycle callbacks run for runtime plugins
  # - Reconfiguration with plugins: works on running services

  use ExUnit.Case, async: false

  # A base plugin providing a callback with a default implementation
  defmodule PluginA do
    use Malla.Plugin

    defcb test_callback(arg) do
      {:plugin_a, arg}
    end

    @impl true
    def plugin_start(srv_id, _config) do
      chain = Malla.Service.get(srv_id, :start_chain, [])
      Malla.Service.put(srv_id, :start_chain, chain ++ [__MODULE__])
      :ok
    end
  end

  # A plugin that depends on PluginA and can intercept callbacks
  defmodule PluginB do
    use Malla.Plugin, plugin_deps: [PluginA]

    defcb test_callback(:intercept) do
      :intercepted_by_b
    end

    defcb test_callback(_arg) do
      :cont
    end

    @impl true
    def plugin_start(srv_id, _config) do
      chain = Malla.Service.get(srv_id, :start_chain, [])
      Malla.Service.put(srv_id, :start_chain, chain ++ [__MODULE__])
      :ok
    end
  end

  # Service with PluginA at compile time. We can override with PluginB at runtime.
  # Since PluginB depends on PluginA and implements the same callbacks,
  # the compile-time dispatch stubs already exist.
  defmodule TestService do
    use Malla.Service,
      class: :test_runtime,
      vsn: "1.0.0",
      plugins: [PluginA]

    defcb test_callback(:at_service) do
      :handled_by_service
    end

    defcb test_callback(_arg) do
      :cont
    end
  end

  # Service with PluginB at compile time (brings in PluginA via deps).
  # We can start it with plugins: [] to test stripping all plugins.
  defmodule FullService do
    use Malla.Service,
      class: :test_runtime_full,
      vsn: "1.0.0",
      plugins: [PluginB]

    defcb test_callback(:at_service) do
      :handled_by_service
    end

    defcb test_callback(_arg) do
      :cont
    end
  end

  setup do
    on_exit(fn ->
      for srv <- [TestService, FullService] do
        pid = Process.whereis(srv)

        if pid && Process.alive?(pid) do
          try do
            srv.stop()
            Process.sleep(50)
          catch
            _, _ -> :ok
          end
        end
      end
    end)
  end

  describe "runtime plugins at start_link" do
    test "service starts with compile-time plugins when none specified at runtime" do
      {:ok, _pid} = TestService.start_link([])
      Process.sleep(50)

      assert :running == TestService.get_status()

      # Compile-time plugins: [PluginA]
      %{plugin_chain: chain} = TestService.service()
      assert TestService in chain
      assert PluginA in chain
      assert Malla.Plugins.Base in chain
    end

    test "runtime plugins replace compile-time plugins" do
      # TestService has PluginA at compile time; start with PluginB instead
      {:ok, _pid} = TestService.start_link(plugins: [PluginB])
      Process.sleep(50)

      assert :running == TestService.get_status()

      %{plugin_chain: chain} = TestService.service()
      # PluginB depends on PluginA, so both should be in the chain
      assert PluginB in chain
      assert PluginA in chain

      # PluginB should come before PluginA (higher priority)
      assert Enum.find_index(chain, &(&1 == PluginB)) <
               Enum.find_index(chain, &(&1 == PluginA))
    end

    test "callbacks dispatch through runtime plugin chain" do
      # Start with PluginB (which intercepts :intercept)
      {:ok, _pid} = TestService.start_link(plugins: [PluginB])
      Process.sleep(50)

      # Service-level interception still works
      assert TestService.test_callback(:at_service) == :handled_by_service

      # PluginB intercepts :intercept
      assert TestService.test_callback(:intercept) == :intercepted_by_b

      # Other values fall through to PluginA
      assert TestService.test_callback(:hello) == {:plugin_a, :hello}
    end

    test "empty plugins list removes all plugins" do
      # FullService has PluginB (and PluginA via deps) at compile time
      {:ok, _pid} = FullService.start_link(plugins: [])
      Process.sleep(50)

      assert :running == FullService.get_status()

      %{plugin_chain: chain} = FullService.service()
      # Only FullService and Base should remain
      assert chain == [FullService, Malla.Plugins.Base]

      # Service-level callback still works
      assert FullService.test_callback(:at_service) == :handled_by_service
    end

    test "runtime plugins with dependencies are resolved correctly" do
      # Start TestService with PluginB (which depends on PluginA)
      {:ok, _pid} = TestService.start_link(plugins: [PluginB])
      Process.sleep(50)

      %{plugin_chain: chain} = TestService.service()

      # Full chain should be: TestService, PluginB, PluginA, Base
      assert [TestService, PluginB, PluginA, Malla.Plugins.Base] == chain
    end

    test "lifecycle callbacks run for runtime plugins" do
      {:ok, _pid} = TestService.start_link(plugins: [PluginB])
      Process.sleep(50)

      # plugin_start is called bottom-up: PluginA first, then PluginB
      start_chain = Malla.Service.get(TestService, :start_chain, [])
      assert PluginA in start_chain
      assert PluginB in start_chain
      assert Enum.find_index(start_chain, &(&1 == PluginA)) <
               Enum.find_index(start_chain, &(&1 == PluginB))
    end

    test "service info reflects runtime plugin chain" do
      {:ok, _pid} = TestService.start_link(plugins: [PluginB])
      Process.sleep(50)

      {:ok, info} = Malla.Service.get_service_info(TestService)
      assert info.id == TestService
      assert info.running_status == :running
      # Callbacks should include test_callback
      assert {:test_callback, 1} in info.callbacks
    end
  end

  describe "reconfiguration with plugins" do
    test "reconfigure can change plugins on a running service" do
      # Start with only PluginA (explicit to ensure known state)
      {:ok, _pid} = TestService.start_link(plugins: [PluginA])
      Process.sleep(50)

      # Verify initial chain has PluginA only
      %{plugin_chain: chain_before} = TestService.service()
      assert PluginA in chain_before
      refute PluginB in chain_before

      # Callback goes through PluginA only
      assert TestService.test_callback(:hello) == {:plugin_a, :hello}
      # No interception for :intercept since PluginB is not loaded
      assert TestService.test_callback(:intercept) == {:plugin_a, :intercept}

      # Reconfigure with PluginB
      :ok = Malla.Service.reconfigure(TestService, plugins: [PluginB])
      Process.sleep(100)

      %{plugin_chain: chain_after} = TestService.service()
      assert PluginB in chain_after
      assert PluginA in chain_after

      # Now :intercept is handled by PluginB
      assert TestService.test_callback(:intercept) == :intercepted_by_b
      # Other values still fall through to PluginA
      assert TestService.test_callback(:hello) == {:plugin_a, :hello}
    end
  end
end
