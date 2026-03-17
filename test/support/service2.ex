defmodule Service2 do
  @moduledoc false

  # Test service demonstrating advanced Malla features.
  #
  # This service showcases more sophisticated patterns compared to Service1,
  # including:
  # - Global service registration (`:global` option)
  # - Service lifecycle callbacks with full implementation
  # - Configuration merging with `plugin_config_merge/3`
  # - Status change monitoring with `service_status_changed/2`
  # - Multi-level callback chains across three callback types
  #
  # **Plugin chain:**
  # ```
  # Service2 → Plugin2_1 → Plugin2_2 → Malla.Plugins.Base
  # ```
  #
  # Note: Plugin2_2 has an optional dependency on Plugin3 which is not
  # declared in the service, so Plugin3 won't be included.
  #

  use Malla.Service,
    class: :test,
    vsn: "v1",
    plugins: [Plugin2_1],
    global: true,
    # config expected
    plugin2_1: %{a: 1},
    service2: %{a: 3}

  # Service-only callback with no plugin implementations.
  #
  # This callback is implemented only at the service level, demonstrating
  # that not all callbacks need to form chains.
  #
  defcb cb_only_service(), do: :only_service

  # Two-level callback chain: Service → Plugin2_1.
  #   Callback Chain: `[Service2, Plugin2_1]`
  #
  defcb cb_plug1_and_service(:srv), do: :srv
  defcb cb_plug1_and_service(:plug1), do: :cont
  defcb cb_plug1_and_service(op), do: {:cont, [op]}

  # Three-level callback chain: Service → Plugin2_1 → Plugin2_2.
  # Callback Chain: `[Service2, Plugin2_1, Plugin2_2]`
  #
  defcb cb_plug2_plug1_and_service(:srv), do: :srv
  defcb cb_plug2_plug1_and_service({:srv, op}), do: {:cont, [{:srv, op}]}
  defcb cb_plug2_plug1_and_service(_op), do: :cont

  # System callback monitoring service status changes.
  #
  # Called whenever the service transitions between states:
  # - `:starting` → `:running`
  # - `:running` → `:paused`
  # - `:paused` → `:running`
  # - `:running` → `:stopped`
  # - etc.
  #
  # This implementation logs the status change and continues the chain,
  # allowing plugins to also monitor status changes.
  #
  defcb service_config(config) do
    Malla.Config.put(Service2, :service_config_config, config)
    :cont
  end

  defcb service_status_changed(_status) do
    # IO.puts("STATUS: #{inspect(status)}")
    # let next plugin be notified
    :cont
  end

  # Plugin lifecycle callback for custom configuration merging.
  #
  # This callback is invoked when the service is reconfigured via
  # `Service.reconfigure/1`. It allows custom merge logic beyond
  # simple deep keyword merging.
  #
  # This implementation:
  # 1. Extracts `:a` and `:b` keys from update
  # 2. Merges those into old config
  # 3. Returns merged config
  #
  # ## Parameters
  # - `_srv_id` - Service ID (not used in this example)
  # - `old_config` - Current configuration (keyword list)
  # - `update` - New configuration to merge (keyword list)
  #
  # ## Returns
  # `{:ok, merged_config}` with the result of merging `:a` and `:b`
  #
  @impl true
  def plugin_config_merge(_srv_id, config, update) do
    # IO.puts("PLUGIN CONFIG MERGE #{__MODULE__}")
    chain = Malla.Config.get(Service2, :config_merge_chain, [])
    Malla.Config.put(Service2, :config_merge_chain, chain ++ [__MODULE__])

    case update[:service2] do
      nil ->
        :ok

      my_update ->
        my_config = config |> Keyword.get(:service2, %{}) |> Map.merge(my_update)
        {:ok, Keyword.put(config, :service2, my_config)}
    end
  end

  # Lifecycle callback: Configuration validation/modification phase.
  #
  # Called during service initialization before starting. This is NOT part
  # of the callback chain system - it's a standard Elixir callback.
  #
  # Called top-down through plugin hierarchy:
  # 1. Service2.plugin_config
  # 2. Plugin2_1.plugin_config
  # 3. Plugin2_2.plugin_config
  #
  @impl true
  def plugin_config(Service2, config) do
    chain = Malla.Config.get(Service2, :config_chain, [])
    Malla.Config.put(Service2, :config_chain, chain ++ [__MODULE__])

    case config[:service2] do
      nil ->
        :ok

      %{a: a} ->
        my_config = %{a: a, b: a + 1}
        {:ok, Keyword.put(config, :service2, my_config)}
    end
  end

  # Lifecycle callback: Service startup initialization.
  #
  # Called during service start after configuration phase. This is NOT part
  # of the callback chain system - it's a standard Elixir callback.
  #
  # Called bottom-up through plugin hierarchy:
  # 1. Plugin2_2.plugin_start (returns :ok)
  # 2. Plugin2_1.plugin_start (returns child spec)
  # 3. Service2.plugin_start (returns :ok)
  #
  # ## Note
  # Unlike Plugin2_1, this service doesn't start any supervised children.
  #
  @impl true
  def plugin_start(Service2, _config) do
    Service2 = Malla.get_service_id!()
    # check start order is correct
    chain = Malla.Service.get(Service2, :start_chain, [])
    Malla.Service.put(Service2, :start_chain, chain ++ [__MODULE__])
    :ok
  end

  # Lifecycle callback: Service shutdown cleanup.
  #
  # Called during service stop before supervised children are terminated.
  # This is NOT part of the callback chain system - it's a standard
  # Elixir callback.
  #
  # Called top-down through plugin hierarchy:
  # 1. Service2.plugin_stop
  # 2. Plugin2_1.plugin_stop
  # 3. Plugin2_2.plugin_stop
  # 4. [Then supervised children are stopped]
  #
  @impl true
  def plugin_stop(Service2, _config) do
    chain = Malla.Config.get(Service2, :stop_chain, [])
    Malla.Config.put(Service2, :stop_chain, chain ++ [__MODULE__])
    :ok
  end

  # Lifecycle callback: Configuration update notification.
  #
  # Called when service configuration is updated via `Service.reconfigure/1`.
  # Plugins can inspect the changes and decide whether to trigger a restart.
  #
  # Called top-down through plugin hierarchy when config changes:
  # 1. Service2.plugin_updated
  # 2. Plugin2_1.plugin_updated
  # 3. Plugin2_2.plugin_updated
  #
  @impl true
  def plugin_updated(_id, _old, _new) do
    chain = Malla.Config.get(Service2, :updated_chain, [])
    Malla.Config.put(Service2, :updated_chain, chain ++ [__MODULE__])
    :ok
  end
end
