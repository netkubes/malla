defmodule Malla.PluginGroupOrderTest do
  @moduledoc false
  # Ordering of plugin groups (`use Malla.Plugin, group: :g`), as documented in
  # the `:group` typedoc of `Malla.Plugin` and guides/04-plugins.md: for
  # `plugins: [A, B, C]` all in one group, each plugin depends on the previous
  # one, so they start A -> B -> C and callbacks run Service -> C -> B -> A.

  use ExUnit.Case, async: false

  defmodule Trace do
    @moduledoc false
    def add(name), do: Process.put(:group_trace, [name | Process.get(:group_trace, [])])
    def take, do: Enum.reverse(Process.delete(:group_trace) || [])
  end

  defmodule A do
    use Malla.Plugin, group: :g

    @impl true
    def plugin_start(_srv_id, _config), do: Malla.PluginGroupOrderTest.Report.started(A)

    defcb group_trace() do
      Trace.add(A)
      :cont
    end
  end

  defmodule B do
    use Malla.Plugin, group: :g

    @impl true
    def plugin_start(_srv_id, _config), do: Malla.PluginGroupOrderTest.Report.started(B)

    defcb group_trace() do
      Trace.add(B)
      :cont
    end
  end

  defmodule C do
    use Malla.Plugin, group: :g

    @impl true
    def plugin_start(_srv_id, _config), do: Malla.PluginGroupOrderTest.Report.started(C)

    defcb group_trace() do
      Trace.add(C)
      :cont
    end
  end

  defmodule Report do
    @moduledoc false
    def started(plugin) do
      case Application.get_env(:malla, :plugin_group_order_test_pid) do
        pid when is_pid(pid) -> send(pid, {:started, plugin})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule GroupService do
    use Malla.Service, plugins: [A, B, C]

    defcb group_trace() do
      Trace.add(GroupService)
      :cont
    end
  end

  test "plugin_chain order of a group declared as [A, B, C]" do
    assert GroupService.service().plugin_chain == [GroupService, C, B, A, Malla.Plugins.Base]
  end

  test "a shared defcb is invoked Service -> C -> B -> A" do
    assert :cont == GroupService.group_trace()
    assert Trace.take() == [GroupService, C, B, A]
  end

  test "plugins are started A -> B -> C" do
    Application.put_env(:malla, :plugin_group_order_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:malla, :plugin_group_order_test_pid)

      if Process.whereis(GroupService) do
        try do
          GroupService.stop()
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, _pid} = GroupService.start_link()
    assert {:ok, %{running_status: :running}} = Malla.Service.get_service_info(GroupService)

    assert_received {:started, first}
    assert_received {:started, second}
    assert_received {:started, third}
    assert [first, second, third] == [A, B, C]

    GroupService.stop()
  end
end
