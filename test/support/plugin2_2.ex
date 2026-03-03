defmodule Plugin2_2 do
  @moduledoc false

  # Base plugin demonstrating optional dependencies and base callback implementations.
  #
  # Position in chain: Service2 → Plugin2_1 → Plugin2_2 → Malla.Plugins.Base
  # This plugin declares an optional dependency on Plugin3.
  # Since Plugin3 is not declared in Service2's plugins list, it won't be
  # included in the plugin chain. Optional dependencies are useful when:

  use Malla.Plugin,
    plugin_deps: [{Plugin2_3, optional: true}]

  # Single-implementation callback only in Plugin2_2.
  defcb cb_only_plugin2(), do: :only_plugin2

  # This callback is implemented by Service2, Plugin2_1, and Plugin2_2
  # [Service2, Plugin2_1, Plugin2_2] - This is the last (base) implementation
  defcb cb_plug2_plug1_and_service(op), do: {:plug2, op}

  # Lifecycle callback: Configuration validation/modification phase.
  @impl true
  def plugin_config(Service2, config) do
    chain = Malla.Config.get(Service2, :config_chain, [])
    Malla.Config.put(Service2, :config_chain, chain ++ [__MODULE__])

    # Process plugin2_2 config: add b: a+1 to the plugin's config map
    case config[:plugin2_2] do
      nil ->
        {:ok, config}

      %{a: a} ->
        my_config = %{a: a, b: a + 1}
        {:ok, Keyword.put(config, :plugin2_2, my_config)}
    end
  end

  # Lifecycle callback: Configuration merge during reconfiguration.
  @impl true
  def plugin_config_merge(_srv_id, config, update) do
    chain = Malla.Config.get(Service2, :config_merge_chain, [])
    Malla.Config.put(Service2, :config_merge_chain, chain ++ [__MODULE__])

    case update[:plugin2_2] do
      nil ->
        :ok

      my_update ->
        my_config = config |> Keyword.get(:plugin2_2, %{}) |> Map.merge(my_update)
        {:ok, Keyword.put(config, :plugin2_2, my_config)}
    end
  end

  # Lifecycle callback: Service startup initialization.
  @impl true
  def plugin_start(Service2, _config) do
    Service2 = Malla.get_service_id!()
    start_chain = Malla.Service.get(Service2, :start_chain, [])
    Malla.Service.put(Service2, :start_chain, start_chain ++ [__MODULE__])
    :ok
  end

  # Lifecycle callback: Service shutdown cleanup.
  @impl true
  def plugin_stop(Service2, _config) do
    chain = Malla.Config.get(Service2, :stop_chain, [])
    Malla.Config.put(Service2, :stop_chain, chain ++ [__MODULE__])
    :ok
  end

  # Lifecycle callback: Configuration update notification.
  @impl true
  def plugin_updated(_id, _old, _new) do
    chain = Malla.Config.get(Service2, :updated_chain, [])
    Malla.Config.put(Service2, :updated_chain, chain ++ [__MODULE__])
    # no restart needed
    :ok
  end
end
