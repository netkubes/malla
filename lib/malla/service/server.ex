## -------------------------------------------------------------------
##
## Copyright (c) 2026 Carlos Gonzalez Florido.  All Rights Reserved.
##
## This file is provided to you under the Apache License,
## Version 2.0 (the "License"); you may not use this file
## except in compliance with the License.  You may obtain
## a copy of the License at
##
##   http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing,
## software distributed under the License is distributed on an
## "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
## KIND, either express or implied.  See the License for the
## specific language governing permissions and limitations
## under the License.
##
## -------------------------------------------------------------------

defmodule Malla.Service.Server do
  @moduledoc false

  require Logger
  use GenServer

  alias Malla.Service

  @doc false
  def get_running_info(srv_id, timeout \\ 5000),
    do: GenServer.call(srv_id, :get_running_info, timeout)

  @doc false
  @spec get_all_local :: [
          %{
            id: Malla.id(),
            class: Malla.class(),
            hash: pos_integer(),
            pid: pid
          }
        ]

  def get_all_local(),
    do: for({pid, values} <- Malla.Registry.values(__MODULE__), do: Map.put(values, :pid, pid))

  @doc false
  @spec get_all_global_pids() :: [pid]
  def get_all_global_pids(), do: :pg.get_members(Malla.Services2, :all)

  @doc false
  @spec get_all_global_pids(Malla.id()) :: [pid]
  def get_all_global_pids(srv_id), do: :pg.get_members(Malla.Services2, srv_id)

  @doc false
  def get_info_all do
    get_all_global_pids()
    |> Enum.reduce(fn pid, acc ->
      try do
        {:ok, info} = Malla.Service.get_service_info(pid)
        [info | acc]
      rescue
        _ -> acc
      end
    end)
  end

  # @doc """
  # Triggers a manual recompilation of the dispatch module

  # If the configuration was changed in run-time, compiled one will
  # match it now (using Service.service())
  # """

  @doc false
  def recompile(srv_id),
    do: GenServer.call(srv_id, :recompile, :infinity)

  ## ===================================================================
  ## gen_server
  ## ===================================================================

  alias __MODULE__, as: State

  @server_check_time 5000
  @type admin_status :: Malla.Service.admin_status()
  @type running_status :: Malla.Service.running_status()

  @type t ::
          %__MODULE__{
            id: Malla.id(),
            admin_status: admin_status,
            running_status: running_status,
            last_status_time: pos_integer,
            last_status_reason: String.t(),
            last_error: term,
            last_error_time: pos_integer,
            service: Malla.Service.t(),
            hash: integer,
            plugins: %{module() => nil | {pid | :none, keyword}}
          }

  defstruct id: nil,
            admin_status: nil,
            running_status: nil,
            last_status_time: 0,
            last_status_reason: nil,
            last_error: nil,
            last_error_time: 0,
            service: nil,
            hash: 0,
            plugins: %{}

  @impl true
  def init([srv_id, update]) do
    if not function_exported?(srv_id, :service, 0), do: raise("Service '#{srv_id}' not defined!")
    _table = :ets.new(srv_id, [:named_table, :public])
    _old_flag = :erlang.process_flag(:trap_exit, true)
    Malla.put_service_id(srv_id)
    service = srv_id.service()

    %Service{id: ^srv_id, class: class, global: global, start_paused: paused} = service
    # wait_for_services(service.wait_for_services, 30)

    # Extract runtime plugins before processing config
    {runtime_plugins, update} = Keyword.pop(update, :plugins)

    if global do
      :ok = :pg.join(Malla.Services2, srv_id, self())
      :ok = :pg.join(Malla.Services2, :all, self())
    end

    {admin_status, running_status} =
      if paused do
        {:paused, :pausing}
      else
        {:active, :starting}
      end

    state = %State{
      id: srv_id,
      admin_status: admin_status,
      running_status: running_status,
      last_status_reason: "init",
      last_status_time: System.os_time(:millisecond),
      service: service
    }

    # If runtime plugins provided, rebuild the plugin chain
    state =
      case runtime_plugins do
        nil ->
          state

        plugins when is_list(plugins) ->
          case do_update_plugin_chain(plugins, state) do
            {:ok, state} -> state
            {:error, error} -> raise "Failed to set runtime plugins: #{inspect(error)}"
          end
      end

    # we first apply otp_app config, if present
    # then we apply on top this update
    case init_config(state, update) do
      {:ok, state} ->
        values = %{
          id: srv_id,
          class: class,
          hash: state.hash
        }

        _ref1 = Malla.Registry.store(__MODULE__, values)
        _ref2 = Malla.Registry.store({__MODULE__, srv_id}, {class, state.hash})
        msg(state, "server started") |> Logger.info()
        send(self(), :timed_check_status)
        {:ok, state}

      {:error, error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call(:get_service_info, _from, state),
    do: {:reply, {:ok, do_get_service_info(state)}, state}

  def handle_call(:get_running_info, _from, state) do
    {running, info} = do_get_running_info(state)
    {:reply, {:ok, {running, info}}, state}
  end

  def handle_call({:set_admin_status, new_admin_status, reason}, _from, %State{} = state) do
    %State{admin_status: admin_status} = state

    case new_admin_status do
      ^admin_status ->
        {:reply, :ok, state}

      _ ->
        new_running_status =
          case new_admin_status do
            :active -> :starting
            :pause -> :pausing
            :inactive -> :stopping
          end

        state = %State{state | admin_status: new_admin_status, last_status_reason: reason}
        state = update_status(state, new_running_status)
        state = check_service_state(state)
        {:reply, :ok, state}
    end
  end

  def handle_call(:get_service, _from, %State{service: service} = state),
    do: {:reply, {:ok, service}, state}

  def handle_call({:reconfigure, update}, _from, state) do
    old_config = state.service.config

    case merge_config(state, update) do
      {:ok, state} ->
        service = state.service
        # we update first the lower services
        chain = Enum.reverse(service.plugin_chain)
        _result = call_plugin_updated(chain, old_config, service)
        {:reply, :ok, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:add_plugin, plugin, opts}, _from, %State{} = state) do
    %State{service: service} = state

    if Enum.member?(service.plugins, plugin) do
      {:reply, :ok, state}
    else
      case Keyword.get(opts, :config) do
        nil ->
          # No config provided, just add the plugin
          do_update_plugins([plugin | service.plugins], state)

        config when is_list(config) ->
          # Config provided: first add plugin to chain, then apply config
          # We need the plugin in the chain so its plugin_config callbacks can process the config
          case do_update_plugin_chain([plugin | service.plugins], state) do
            {:ok, state} ->
              # Now apply the config with the plugin in the chain
              case do_reconfigure(state, config) do
                {:ok, state} ->
                  # Trigger status check to start the plugins with the new config
                  send(self(), :check_status)
                  {:reply, :ok, state}

                {:error, error} ->
                  {:reply, {:error, error}, state}
              end

            {:error, error} ->
              {:reply, {:error, error}, state}
          end
      end
    end
  end

  def handle_call({:del_plugin, plugin}, _from, %State{} = state) do
    %State{service: service} = state

    if Enum.member?(service.plugins, plugin) do
      do_update_plugins(service.plugins -- [plugin], state)
    end
  end

  def handle_call(:recompile, _from, state) do
    _result = Malla.Service.Build.recompile(state.service)
    {:reply, :ok, state}
  end

  # will call terminate
  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_cast({:restart_plugin, plugin}, %State{} = state) do
    %State{plugins: plugins, admin_status: status} = state

    case Map.get(plugins, plugin) do
      nil ->
        # We didn't start this yet
        {:noreply, state}

      {pid, _opts} when status in [:active, :pause] ->
        if is_pid(pid), do: Supervisor.stop(pid)
        state = %State{state | plugins: Map.put(plugins, plugin, nil)}

        case start_plugins(state, [plugin]) do
          {:ok, state} ->
            {:noreply, state}

          {:error, error} ->
            msg(state, "error starting plugins: #{inspect(error)}") |> Logger.warning()
            state = stop_plugins(state)
            {:noreply, update_status(state, {:error, error})}
        end

      {_pid, _opts} ->
        msg(state, plugin, "Not restaring in #{status} status") |> Logger.notice()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:timed_check_status, state) do
    state = check_service_state(state)
    Process.send_after(self(), :timed_check_status, @server_check_time)
    {:noreply, state}
  end

  def handle_info(:check_status, state), do: {:noreply, check_service_state(state)}

  def handle_info({:DOWN, _ref, :process, pid, reason}, %State{} = state) do
    plugin =
      Enum.find_value(state.plugins, fn
        {plugin, {^pid, _opts}} -> plugin
        _ -> false
      end)

    case plugin do
      nil ->
        # it seems we already deleted this
        {:noreply, state}

      plugin ->
        msg(state, plugin, "children sup has failed (#{inspect(reason)})") |> Logger.warning()
        plugins = Map.put(state.plugins, plugin, nil)

        state =
          %State{state | plugins: plugins} |> update_status({:error, {:child_failed, plugin}})

        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    msg(state, "received unexpected info #{inspect(msg)}") |> Logger.info()
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    msg(state, "is stopping, reason: #{inspect(reason)}") |> Logger.notice()
    stop_plugins(state)
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  # Initial config: merge all config layers, call service_config, then plugin_config
  defp init_config(state, update) do
    %State{id: srv_id} = state

    key = srv_id.__service__(:config_key)

    with {:ok, %State{} = state} <- merge_config_only(state, update) do
      :persistent_term.put(key, state.service.config)

      with {:ok, %State{} = state} <- call_service_config(state),
           {:ok, service} <- call_plugin_config(state.service.plugin_chain, state.service) do
        hash = :erlang.phash2(service)
        :persistent_term.put(key, service.config)
        {:ok, %State{state | service: service, hash: hash}}
      end
    end
  end

  defp call_service_config(%State{id: srv_id, service: service} = state) do
    case srv_id.service_config(service.config) do
      {:ok, config} when is_list(config) ->
        {:ok, %State{state | service: %{service | config: config}}}

      {:error, _} = error ->
        error
    end
  end

  # Merge config layers without calling plugin_config
  defp merge_config_only(state, update) do
    case Keyword.get(state.service.config, :otp_app) do
      nil ->
        # msg(state, "init config: #{inspect(update)}") |> Logger.debug()
        do_merge_only(state, update)

      app ->
        app_update = Application.get_env(app, state.id, [])
        # msg(state, "init otp_app config: #{inspect(app_update)}") |> Logger.info()

        case do_merge_only(state, app_update) do
          {:ok, state} ->
            # msg(state, "init config: #{inspect(update)}") |> Logger.debug()
            do_merge_only(state, update)

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp do_merge_only(%State{} = state, update) do
    %State{id: srv_id} = state

    {runtime_plugins, update} = Keyword.pop(update, :plugins)

    state =
      case runtime_plugins do
        nil ->
          state

        plugins when is_list(plugins) ->
          case do_update_plugin_chain(plugins, state) do
            {:ok, state} -> state
            {:error, error} -> raise "Failed to set runtime plugins: #{inspect(error)}"
          end
      end

    %State{service: %Service{} = service} = state

    with :ok <- config_invalid_opts(update),
         {:ok, config} <-
           call_plugin_config_merge(service.plugin_chain, srv_id, service.config, update) do
      service = %Service{service | config: config}
      {:ok, %State{state | service: service}}
    end
  end

  # we first apply reconfig over otp_app, if present in config
  # then we reapply with the included update
  defp merge_config(state, update) do
    case Keyword.get(state.service.config, :otp_app) do
      nil ->
        msg(state, "launch reconfig: #{inspect(update)}") |> Logger.debug()
        do_reconfigure(state, update)

      app ->
        app_update = Application.get_env(app, state.id, [])
        msg(state, "launch otp_app reconfig: #{inspect(app_update)}") |> Logger.info()

        case do_reconfigure(state, app_update) do
          {:ok, state} ->
            msg(state, "launch reconfig: #{inspect(update)}") |> Logger.debug()

            case do_reconfigure(state, update) do
              {:ok, state} ->
                msg(state, "Final config is: #{inspect(state.service.config)}") |> Logger.notice()
                {:ok, state}

              {:error, error} ->
                {:error, error}
            end

          {:error, error} ->
            {:error, error}
        end
    end
  end

  defp do_reconfigure(%State{} = state, update) do
    %State{id: srv_id} = state

    # Extract runtime plugins before checking invalid opts
    {runtime_plugins, update} = Keyword.pop(update, :plugins)

    state =
      case runtime_plugins do
        nil ->
          state

        plugins when is_list(plugins) ->
          case do_update_plugin_chain(plugins, state) do
            {:ok, state} -> state
            {:error, error} -> raise "Failed to set runtime plugins: #{inspect(error)}"
          end
      end

    %State{service: %Service{} = service} = state

    with :ok <- config_invalid_opts(update),
         {:ok, config} <-
           call_plugin_config_merge(service.plugin_chain, srv_id, service.config, update),
         service = %Service{service | config: config},
         {:ok, service} <- call_plugin_config(service.plugin_chain, service) do
      hash = :erlang.phash2(service)
      key = srv_id.__service__(:config_key)
      :persistent_term.put(key, service.config)
      {:ok, %State{state | service: service, hash: hash}}
    end
  end

  defp config_invalid_opts(config) do
    invalid = [:otp_app, :class, :vsn, :global, :paused]

    case Enum.find(config, fn {key, _val} -> if key in invalid, do: key end) do
      nil -> :ok
      {key, _} -> {:error, {:key_not_allowed_in_service_start, key}}
    end
  end

  @spec call_plugin_config_merge([term], Malla.id(), keyword, keyword) ::
          {:ok, keyword} | {:error, term}

  defp call_plugin_config_merge([], _srv_id, config, update) do
    # No plugins handled merge, deep-merge by default
    {:ok, Keyword.merge(config, update)}
  end

  defp call_plugin_config_merge([plugin | rest], srv_id, config, update) do
    # Check if plugin implements plugin_config_merge callback
    if function_exported?(plugin, :plugin_config_merge, 3) do
      case plugin.plugin_config_merge(srv_id, config, update) do
        :ok ->
          # Plugin doesn't handle merge, continue to next
          call_plugin_config_merge(rest, srv_id, config, update)

        {:ok, merged_config} when is_list(merged_config) ->
          # Plugin returned merged config, use it and continue
          call_plugin_config_merge(rest, srv_id, merged_config, update)

        {:error, error} ->
          {:error, error}
      end
    else
      # Plugin doesn't implement plugin_config_merge, skip to next
      call_plugin_config_merge(rest, srv_id, config, update)
    end
  end

  @spec call_plugin_config([term], %Malla.Service{}) :: {:ok, %Malla.Service{}} | {:error, term}

  defp call_plugin_config([], %Malla.Service{} = service), do: {:ok, service}

  defp call_plugin_config([plugin | rest], %Malla.Service{} = service) do
    case plugin.plugin_config(service.id, service.config) do
      :ok ->
        call_plugin_config(rest, service)

      {:ok, config} when is_list(config) ->
        call_plugin_config(rest, %Service{service | config: config})

      {:ok, config} when is_map(config) ->
        {:error, :plugin_config_invalid_return}

      {:error, error} ->
        {:error, error}
    end
  end

  defp call_plugin_updated([], _old_config, _service), do: :ok

  defp call_plugin_updated([plugin | rest], old_config, service) do
    case plugin.plugin_updated(service.id, old_config, service.config) do
      :ok ->
        call_plugin_updated(rest, old_config, service)

      {:ok, opts} when is_list(opts) ->
        if opts[:restart], do: Malla.Service.restart_plugin(service.id, plugin)
        call_plugin_updated(rest, old_config, service)

      {:error, error} ->
        {:error, error}
    end
  end

  defp check_service_state(state) do
    state = stop_removed_plugins(state)

    %State{admin_status: admin_status, running_status: running_status} = state

    case running_status do
      :starting -> start_plugins(state)
      :running -> start_new_plugins(state)
      :pausing -> update_status(state, :paused)
      :paused -> state
      :stopping -> stop_plugins(state)
      :stopped -> state
      :failed when admin_status == :active -> start_plugins(state)
      :failed -> state
    end
  end

  defp start_plugins(%State{service: service} = state) do
    %{plugin_chain: plugins} = service

    # Start first base plugins
    case start_plugins(state, Enum.reverse(plugins)) do
      {:ok, state} ->
        _updated_state = update_status(state, :running)

      {:error, error} ->
        msg(state, "error starting plugins: #{inspect(error)}") |> Logger.warning()
        _stopped_state = stop_plugins(state)
        _updated_state = update_status(state, {:error, error})
    end
  end

  defp start_new_plugins(%State{service: service, plugins: started_plugins} = state) do
    %{plugin_chain: plugin_chain} = service

    # Find plugins in the chain that aren't started yet
    new_plugins =
      Enum.filter(plugin_chain, fn plugin ->
        not Map.has_key?(started_plugins, plugin)
      end)

    case new_plugins do
      [] ->
        state

      plugins_to_start ->
        # Start new plugins in reverse order (base plugins first)
        case start_plugins(state, Enum.reverse(plugins_to_start)) do
          {:ok, state} ->
            state

          {:error, error} ->
            msg(state, "error starting new plugins: #{inspect(error)}") |> Logger.warning()
            update_status(state, {:error, error})
        end
    end
  end

  @spec start_plugins(%State{}, [term]) :: {:ok, %State{}} | {:error, term}

  defp start_plugins(state, []), do: {:ok, state}

  defp start_plugins(%State{} = state, [plugin | rest]) do
    case Map.get(state.plugins, plugin) do
      nil ->
        # we didn't yet start this plugin
        case do_start_plugin(state, plugin) do
          {:ok, sup} ->
            plugins = Map.put(state.plugins, plugin, sup)
            start_plugins(%State{state | plugins: plugins}, rest)

          {:error, error} ->
            {:error, error}
        end

      {sup, _opts} when is_pid(sup) or sup == :none ->
        # this plugin was already started
        start_plugins(state, rest)
    end
  end

  defp do_start_plugin(state, plugin) do
    start = plugin.plugin_start(state.service.id, state.service.config)

    case start do
      :ok ->
        {:ok, {:none, []}}

      {:ok, opts} ->
        case opts[:children] do
          nil ->
            {:ok, {:none, opts}}

          [] ->
            {:ok, {:none, opts}}

          children ->
            options = Keyword.take(opts, [:strategy, :max_restarts, :max_seconds])
            name = sup_name(state, plugin)
            options = [strategy: :one_for_one, name: name] |> Keyword.merge(options)

            case Supervisor.start_link(children, options) do
              {:ok, pid} ->
                Process.monitor(pid)
                {:ok, {pid, opts}}

              {:error, {:already_started, pid}} ->
                Process.monitor(pid)
                {:ok, {pid, opts}}

              {:error, error} ->
                msg(state, plugin, "Could not start child supervisor: #{inspect(error)}")
                |> Logger.warning()

                {:error, :child_sup_error}
            end
        end

      {:error, error} ->
        msg(state, plugin, "start error: #{inspect(error)}") |> Logger.warning()
        {:error, error}
    end
  end

  defp sup_name(%State{id: srv_id}, plugin),
    do: Malla.Registry.via({__MODULE__, :plugin_sup, srv_id, plugin})

  defp stop_plugins(%State{service: service} = state) do
    # stop first top plugins
    stop_plugins(state, service.plugin_chain) |> update_status(:stopped)
  end

  @spec stop_plugins(%State{}, [term]) :: %State{}

  defp stop_plugins(state, []), do: state

  defp stop_plugins(%State{} = state, [plugin | rest]) do
    do_stop_plugin(state, plugin)
    plugins = Map.put(state.plugins, plugin, nil)
    stop_plugins(%State{state | plugins: plugins}, rest)
  end

  defp do_stop_plugin(state, plugin) do
    case plugin.plugin_stop(state.service.id, state.service.config) do
      :ok ->
        :ok

      {:error, error} ->
        msg(state, plugin, "Error stopping plugin: #{inspect(error)}") |> Logger.warning()
    end

    case Map.get(state.plugins, plugin) do
      {pid, _} when is_pid(pid) -> Supervisor.stop(pid)
      _ -> :ok
    end
  end

  @spec stop_removed_plugins(%State{}) :: %State{}

  defp stop_removed_plugins(%State{} = state) do
    %State{service: %{plugin_chain: plugin_chain}, plugins: plugins} = state
    to_remove = for {plugin, _} <- plugins, not Enum.member?(plugin_chain, plugin), do: plugin

    case to_remove do
      [] ->
        state

      _ ->
        msg(state, "Removing plugins: #{inspect(to_remove)}") |> Logger.notice()
        %State{plugins: plugins} = state = stop_plugins(state, to_remove)
        %State{state | plugins: Map.drop(plugins, to_remove)}
    end
  end

  @spec update_status(%State{}, {:error, term()} | running_status()) :: %State{}

  defp update_status(%State{} = state, {:error, error}) do
    msg(state, "status is 'failed': #{inspect(error)}") |> Logger.warning()
    now = System.os_time(:millisecond)

    %State{
      state
      | running_status: :failed,
        last_error: error,
        last_error_time: now,
        last_status_time: now
    }
    |> set_updated_status()
  end

  defp update_status(%State{} = state, new_status) do
    case state.running_status do
      ^new_status ->
        state

      old_status ->
        msg(state, "status updated '#{old_status}' -> '#{new_status}'")
        |> Logger.notice()

        now = System.os_time(:millisecond)

        %State{state | running_status: new_status, last_status_time: now}
        |> set_updated_status()
    end
  end

  defp set_updated_status(state) do
    %State{id: srv_id, running_status: status} = state
    key = srv_id.__service__(:status_key)
    :persistent_term.put(key, status)
    :ok = srv_id.service_status_changed(status)
    {running, info} = do_get_running_info(state)
    # don't wait Node to call us
    Malla.Node.update_service_info_global({running, info})
    state
  end

  defp do_get_service_info(state) do
    state
    |> Map.take([
      :id,
      :class,
      :admin_status,
      :running_status,
      :last_status_time,
      :last_status_reason,
      :last_error,
      :last_error_time,
      :plugins
    ])
    |> Map.put(:vsn, state.service.vsn)
    |> Map.put(:hash, state.hash)
    |> Map.put(:pid, self())
    |> Map.put(:node, node(self()))
    |> Map.put(:callbacks, Enum.map(state.service.callbacks, fn {cb, _} -> cb end))
  end

  # defp do_get_running_info(state) do
  #   %State{id: srv_id, running_status: running_status, service: %{vsn: vsn}} = state
  #   # TODO: call callback to get meta status and help the routing decission by client
  #   data = %{id: srv_id, pid: self(), meta: info}
  #   {running_status == :running, data}
  # end

  defp do_get_running_info(state) do
    info = do_get_service_info(state) |> Map.drop([:plugins])
    # TODO: call callback to get meta status and help the routing decission by client
    data = %{id: info.id, pid: self(), meta: info}
    {info.running_status == :running, data}
  end

  defp msg(state, text),
    do: "Service #{inspect(state.id)}: " <> text

  defp msg(state, plugin, text),
    do: "Service #{inspect(state.id)} (#{inspect(plugin)}): " <> text

  @spec do_update_plugins(term(), %State{}) :: {:reply, :ok | {:error, term()}, %State{}}

  defp do_update_plugins(plugins, %State{} = state) do
    case do_update_plugin_chain(plugins, state) do
      {:ok, state} ->
        send(self(), :check_status)
        {:reply, :ok, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  defp do_update_plugin_chain(plugins, %State{} = state) do
    try do
      %State{id: srv_id, service: %Service{} = service} = state
      attrs = apply(srv_id, :__info__, [:attributes])
      callbacks = for {:plugin_callbacks, cbs} <- attrs, do: cbs

      service =
        %Service{service | plugins: plugins}
        |> Malla.Service.Make.expand_plugins()
        |> Malla.Service.Make.get_callbacks(callbacks)
        |> Malla.Service.Build.recompile()

      {:ok, %State{state | service: service}}
    rescue
      e ->
        msg(state, "Error updating plugins: #{inspect(e)}") |> Logger.warning()
        {:error, e}
    end
  end

  # defp wait_for_services([], _), do: :ok

  # defp wait_for_services([srv_id | rest], tries) when tries > 0 do
  #   case Malla.Node.get_instances(srv_id) do
  #     [] ->
  #       Logger.warning("Waiting for service #{inspect(srv_id)}, #{tries} left")
  #       Process.sleep(1000)
  #       wait_for_services([srv_id | rest], tries - 1)

  #     [_ | _] ->
  #       Logger.notice("Service #{inspect(srv_id)} already available")
  #       wait_for_services(rest, tries - 1)
  #   end
  # end

  # defp wait_for_services([srv_id | _], _),
  #   do: raise("Timeout waiting for service #{inspect(srv_id)}")
end
