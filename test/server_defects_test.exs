defmodule Malla.ServerDefectsTest do
  @moduledoc false
  # Regression tests for defects in `Malla.Service.Server`, one `describe` per defect.

  use ExUnit.Case, async: false

  defmodule PlainPlugin do
    use Malla.Plugin
  end

  defmodule DelPluginService do
    use Malla.Service, plugins: []
  end

  defmodule PausedService do
    use Malla.Service, paused: true, plugins: []
  end

  # Plugins for the failed-start tests. Each reports its plugin_stop/2 call to the
  # test process; OkPlugin starts a child that reports its own pid.
  defmodule Report do
    @moduledoc false
    def send(msg) do
      case Application.get_env(:malla, :server_defects_test_pid) do
        pid when is_pid(pid) -> Kernel.send(pid, msg)
        _ -> :ok
      end

      :ok
    end
  end

  defmodule OkPlugin do
    use Malla.Plugin

    @impl true
    def plugin_start(_srv_id, _config) do
      child = {Agent, fn -> Report.send({:child_started, __MODULE__, self()}) end}
      {:ok, children: [child]}
    end

    @impl true
    def plugin_stop(srv_id, _config), do: Report.send({:plugin_stop, srv_id, __MODULE__})
  end

  defmodule FailPlugin do
    use Malla.Plugin, plugin_deps: [OkPlugin]

    @impl true
    def plugin_start(_srv_id, _config), do: {:error, :boom}

    @impl true
    def plugin_stop(srv_id, _config), do: Report.send({:plugin_stop, srv_id, __MODULE__})
  end

  defmodule NeverPlugin do
    use Malla.Plugin, plugin_deps: [FailPlugin]

    @impl true
    def plugin_stop(srv_id, _config), do: Report.send({:plugin_stop, srv_id, __MODULE__})
  end

  defmodule RunningPlugin do
    use Malla.Plugin

    @impl true
    def plugin_stop(srv_id, _config), do: Report.send({:plugin_stop, srv_id, __MODULE__})
  end

  defmodule FailStartService do
    use Malla.Service, plugins: [NeverPlugin]

    defcb service_status_changed(status) do
      Report.send({:status, __MODULE__, status})
      :cont
    end
  end

  defmodule FailNewPluginService do
    use Malla.Service, plugins: [RunningPlugin]

    defcb service_status_changed(status) do
      Report.send({:status, __MODULE__, status})
      :cont
    end
  end

  defmodule ReconfigureService do
    use Malla.Service, plugins: []
  end

  defmodule AddPluginConfigService do
    use Malla.Service, plugins: []
  end

  defmodule StartBadPluginsService do
    use Malla.Service, plugins: []
  end

  defp stop_service(srv_id) do
    if Process.whereis(srv_id) do
      try do
        srv_id.stop()
      catch
        :exit, _ -> :ok
      end
    end
  end

  describe "del_plugin/2" do
    setup do
      on_exit(fn -> stop_service(DelPluginService) end)
    end

    test "deleting a plugin the service does not have is a no-op" do
      {:ok, pid} = DelPluginService.start_link()

      assert :ok == Malla.Service.del_plugin(DelPluginService, PlainPlugin)
      assert Process.alive?(pid)
      assert {:ok, %{id: DelPluginService}} = Malla.Service.get_service_info(DelPluginService)
      assert DelPluginService.service().plugins == []

      DelPluginService.stop()
    end
  end

  describe "paused: true" do
    setup do
      on_exit(fn -> stop_service(PausedService) end)
    end

    test "starts with the :pause admin status, and setting :pause again is a no-op" do
      {:ok, _pid} = PausedService.start_link()

      assert {:ok, %{admin_status: :pause, running_status: :paused, last_status_reason: "init"}} =
               Malla.Service.get_service_info(PausedService)

      assert :ok == PausedService.set_admin_status(:pause, :again)

      assert {:ok, %{admin_status: :pause, running_status: :paused, last_status_reason: "init"}} =
               Malla.Service.get_service_info(PausedService)

      assert :ok == PausedService.set_admin_status(:active, :resume)
      Process.sleep(50)
      assert :running == PausedService.get_status()

      PausedService.stop()
    end
  end

  describe "a plugin that fails to start" do
    setup do
      Application.put_env(:malla, :server_defects_test_pid, self())

      on_exit(fn ->
        Application.delete_env(:malla, :server_defects_test_pid)
        stop_service(FailStartService)
        stop_service(FailNewPluginService)
      end)
    end

    test "at service start, stops exactly the plugins that started" do
      {:ok, _pid} = FailStartService.start_link()

      # the first status check runs before this call is served
      assert {:ok, %{running_status: :failed, last_error: :boom, plugins: plugins}} =
               Malla.Service.get_service_info(FailStartService)

      # OkPlugin started (its child too) and was stopped; its supervisor is gone
      assert_received {:child_started, OkPlugin, child}
      refute Process.alive?(child)
      assert_received {:plugin_stop, FailStartService, OkPlugin}
      assert Map.get(plugins, OkPlugin) == nil

      # FailPlugin and NeverPlugin never started, so they are not stopped
      refute_received {:plugin_stop, FailStartService, FailPlugin}
      refute_received {:plugin_stop, FailStartService, NeverPlugin}

      # the service goes straight to :failed, without a :stopped notification
      assert_received {:status, FailStartService, :failed}
      refute_received {:status, FailStartService, :stopped}

      FailStartService.stop()
    end

    test "added at run-time, stops the plugins started for it and keeps the others" do
      {:ok, _pid} = FailNewPluginService.start_link()

      assert {:ok, %{running_status: :running}} =
               Malla.Service.get_service_info(FailNewPluginService)

      assert_received {:status, FailNewPluginService, :running}

      assert :ok == Malla.Service.add_plugin(FailNewPluginService, FailPlugin)

      assert {:ok, %{running_status: :failed, last_error: :boom, plugins: plugins}} =
               Malla.Service.get_service_info(FailNewPluginService)

      # OkPlugin was started for FailPlugin, then stopped with its children
      assert_received {:child_started, OkPlugin, child}
      refute Process.alive?(child)
      assert_received {:plugin_stop, FailNewPluginService, OkPlugin}
      assert Map.get(plugins, OkPlugin) == nil

      # the plugin that was already running is untouched
      refute_received {:plugin_stop, FailNewPluginService, RunningPlugin}
      assert {:none, _} = Map.get(plugins, RunningPlugin)
      refute_received {:plugin_stop, FailNewPluginService, FailPlugin}

      FailNewPluginService.stop()
    end
  end

  describe "a runtime plugin list that cannot be built" do
    setup do
      on_exit(fn ->
        stop_service(ReconfigureService)
        stop_service(AddPluginConfigService)
        stop_service(StartBadPluginsService)
      end)
    end

    test "reconfigure/2 returns the error and the service keeps running" do
      {:ok, pid} = ReconfigureService.start_link()

      assert {:error, _} =
               ReconfigureService.reconfigure(plugins: [Malla.ServerDefectsTest.NoSuchPlugin])

      assert Process.alive?(pid)

      assert {:ok, %{running_status: :running}} =
               Malla.Service.get_service_info(ReconfigureService)

      assert ReconfigureService.service().plugins == []

      ReconfigureService.stop()
    end

    test "add_plugin/3 with config: returns the error and the service keeps running" do
      {:ok, pid} = AddPluginConfigService.start_link()

      assert {:error, _} =
               Malla.Service.add_plugin(AddPluginConfigService, PlainPlugin,
                 config: [plugins: [Malla.ServerDefectsTest.NoSuchPlugin]]
               )

      assert Process.alive?(pid)

      assert {:ok, %{running_status: :running}} =
               Malla.Service.get_service_info(AddPluginConfigService)

      AddPluginConfigService.stop()
    end

    test "start_link/1 fails with the error" do
      Process.flag(:trap_exit, true)

      assert {:error, %RuntimeError{message: "Cannot find plugin " <> _}} =
               StartBadPluginsService.start_link(plugins: [Malla.ServerDefectsTest.NoSuchPlugin])

      refute Process.whereis(StartBadPluginsService)
    end
  end
end
