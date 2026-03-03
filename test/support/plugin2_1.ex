defmodule Plugin2_1 do
  @moduledoc false
  # Plugin demonstrating supervised child processes and callback chain participation.
  #
  # Position in chain: Service2 → Plugin2_1 → Plugin2_2 → Malla.Plugins.Base
  # Plugin2_1 depends on Plugin2_2, placing it earlier in the callback chain.
  #

  defmodule Child do
    @moduledoc false
    # Supervised child process started by Plugin2_1.
    #
    # This GenServer demonstrates how plugins can start supervised processes
    # that are automatically managed by the service's supervision tree.
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: Plugin2_1.Child)
    def init(_), do: {:ok, nil}
  end

  # Mark this plugin depends on Plugin2_2
  use Malla.Plugin,
    plugin_deps: [Plugin2_2]

  # Single-implementation callback only in Plugin2_1.
  #
  # This demonstrates that callbacks don't need to form chains - a single
  # plugin can implement a callback that no other plugin or service touches.
  defcb cb_only_plugin1(), do: :only_plugin1

  # Base implementation for two-level callback chain.
  #
  # This callback is implemented by both Plugin2_1 and Service2
  # Callback Chain Position: [Service2, Plugin2_1]
  defcb cb_plug1_and_service(op), do: {:plug1, op}

  # Mid-level implementation for three-level callback chain.
  #
  # This callback is implemented by Service2, Plugin2_1, and Plugin2_2
  defcb cb_plug2_plug1_and_service(:plug1), do: :plug1
  defcb cb_plug2_plug1_and_service({:plug1, op}), do: {:cont, [{:plug1, op}]}
  defcb cb_plug2_plug1_and_service(_op), do: :cont

  # Lifecycle callback: Configuration validation/modification phase.
  @impl true
  def plugin_config(Service2, config) do
    Service2 = Malla.get_service_id!()
    chain = Malla.Config.get(Service2, :config_chain, [])
    Malla.Config.put(Service2, :config_chain, chain ++ [__MODULE__])

    case config[:plugin2_1] do
      nil ->
        :ok

      %{a: a} ->
        my_config = %{a: a, b: a + 1}
        {:ok, Keyword.put(config, :plugin2_1, my_config)}
    end
  end

  # Lifecycle callback: Configuration merge during reconfiguration.
  @impl true
  def plugin_config_merge(_srv_id, config, update) do
    chain = Malla.Config.get(Service2, :config_merge_chain, [])
    Malla.Config.put(Service2, :config_merge_chain, chain ++ [__MODULE__])

    case update[:plugin2_1] do
      nil ->
        :ok

      my_update ->
        my_config = config |> Keyword.get(:plugin2_1, %{}) |> Map.merge(my_update)
        {:ok, Keyword.put(config, :plugin2_1, my_config)}
    end
  end

  # Lifecycle callback: Service startup initialization.
  #
  # Called during service start after configuration phase. This is NOT part
  # of the callback chain system - it's a standard Elixir callback.
  #
  # This implementation starts a supervised child GenServer.
  #
  @impl true
  def plugin_start(Service2, _config) do
    Service2 = Malla.get_service_id!()
    chain = Malla.Service.get(Service2, :start_chain, [])
    Malla.Service.put(Service2, :start_chain, chain ++ [__MODULE__])
    {:ok, children: [Plugin2_1.Child]}
  end

  # Lifecycle callback: Service shutdown cleanup.
  #
  # Called during service stop before supervised children are terminated.
  # This is NOT part of the callback chain system - it's a standard
  # Elixir callback.
  @impl true
  def plugin_stop(Service2, _config) do
    chain = Malla.Config.get(Service2, :stop_chain, [])
    Malla.Config.put(Service2, :stop_chain, chain ++ [__MODULE__])
    :ok
  end

  # Lifecycle callback: Configuration update notification.
  @impl true
  def plugin_updated(_id, old, new) do
    chain = Malla.Config.get(Service2, :updated_chain, [])
    Malla.Config.put(Service2, :updated_chain, chain ++ [__MODULE__])

    # Trigger restart if plugin2_1 config changed
    if old[:plugin2_1] != new[:plugin2_1] do
      {:ok, restart: true}
    else
      :ok
    end
  end
end
