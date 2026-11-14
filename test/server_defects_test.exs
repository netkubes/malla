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
end
