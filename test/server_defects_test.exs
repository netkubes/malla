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
end
