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
## -----------------------------------------------j--------------------

defmodule Malla.Node do
  @check_services_time 10000

  @moduledoc """
  Manages distributed Malla services across a cluster of nodes.

  `Malla.Node` is a `GenServer` that monitors services, performs health checks,
  and provides tools for remote procedure calls (RPC). It is the core of Malla's
  service discovery mechanism.

  When a `Malla.Service` is defined with `global: true`, it registers with `Malla.Node`,
  making it discoverable by other nodes in the cluster.

  Key features include:
  - **Service Discovery**: Tracks which services are running on which nodes.
  - **RPC Calls**: Provides `call/4`, `call_cb/4` and `call_cb_all/4` to invoke functions on
    remote services with automatic failover.
  - **Health Checks**: Periodically re-checks all services on the network.
  - **Virtual Modules**: Can dynamically generate proxy modules to make remote
    calls transparent.

  For more information on how services are discovered and called, see the guides:
  - **[Service Discovery](guides/08-distribution/02-service-discovery.md)**
  - **[Remote Calls](guides/08-distribution/03-remote-calls.md)**
  """

  use GenServer

  @typedoc false
  @type state :: __MODULE__

  alias __MODULE__, as: State
  alias Malla.Service.Server

  require Logger

  @rpc_timeout 30000

  ## ===================================================================
  ## API
  ## ===================================================================

  @type service_info :: Malla.Service.service_info()

  @type service_info_message :: %{
          id: atom(),
          pid: pid(),
          meta: service_info()
        }

  @type instance_status ::
          {node, metadata :: service_info()}

  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]}
    }
  end

  @doc """
    Gets all nodes implementing a specific service if it is in _running_ state at that node,
    along with metadata.

    If the local node is running the service, it will be first in the list.
    The rest will shuffle every service recheck for load-balancing purposes.
  """
  @spec get_instances(Malla.id()) :: [instance_status]
  def get_instances(srv_id),
    do: Malla.Config.get(__MODULE__, {:service_running_data, srv_id}, [])

  @doc """
    Gets all nodes implementing a specific service if it is in _running_ state at that node.

    If the local node is running the service, it will be first in the list.
    The rest will shuffle every service recheck for load-balancing purposes.
  """
  @spec get_nodes(Malla.id()) :: [node()]
  def get_nodes(srv_id) do
    for {node, _meta} <- get_instances(srv_id), do: node
  end

  @doc """
  Retrieves all detected _service ids_, their corresponding _pids_ and _metadata_.
  """
  @spec get_services() :: %{
          services_info: %{pid() => {Malla.id(), meta: service_info()}},
          services_id: [Malla.id()]
        }

  def get_services(), do: GenServer.call(__MODULE__, :get_services)

  @doc """
  Waits for all services in the list to become available by checking `get_nodes/1`.

  Options can include `:retries` (default 10) for number of attempts, with 1-second sleeps between retries.

  Returns `:ok` if all services are available, `:timeout` otherwise.
  """
  @spec wait_for_services([Malla.id()], keyword()) :: :ok | :timeout

  def wait_for_services(list, opts \\ [])

  def wait_for_services([], _opts), do: :ok

  def wait_for_services([srv_id | rest], opts) do
    case get_nodes(srv_id) do
      [] ->
        case Keyword.get(opts, :retries, 10) do
          retries when is_integer(retries) and retries > 0 ->
            Logger.warning("Waiting for service #{inspect(srv_id)} (#{retries} retries)")
            Process.sleep(1000)
            opts = Keyword.put(opts, :retries, retries - 1)
            wait_for_services([srv_id | rest], opts)

          _ ->
            :timeout
        end

      [_ | _] ->
        wait_for_services(rest, opts)
    end
  end

  # if timeout=0, means 'dont wait any answer'
  @type call_opt ::
          {:timeout, timeout}
          | {:service_id, Malla.id()}
          | {:nodes, [node()]}

  @type call_result ::
          {:error, :malla_service_not_available | {:malla_rpc, {term(), String.t()}}} | term

  @doc """
    Launches a call to a any module and function at a remote node.

    A node list is obtained from `nodes` parameter, or, if not present,
    a _service's id_ must be obtained from `service_id` parameter or
    must be present in process dictionary (see `Malla.put_service_id/1`).
    Then we will use `get_nodes/1` to find nodes running this service.

    First node in the list will be called and, only if it returns `{:error, :malla_service_not_available}` from remote,
    the next one is tried. If the local node is running the service, it will be called first.

    Returns `{:error, :malla_service_not_available}` if we exhaust the instances and none is available.
    Returns `{:error, {:malla_rpc, {term, text}}}` if an exception is produced remotely or in `:erpc.call/5`.

    If `:timeout` is set to zero, call will be asynchronous.
  """

  @spec call(module, atom, list, [call_opt]) :: call_result()

  def call(mod, fun, args, opts \\ []) do
    nodes =
      case Keyword.get(opts, :nodes) do
        nil ->
          srv_id = Malla.get_service_id!(opts)
          get_nodes(srv_id)

        nodes ->
          nodes
      end

    do_call(nodes, mod, fun, args, opts)
  end

  defp do_call([], _mod, _fun, _args, _opts),
    do: {:error, :malla_service_not_available}

  defp do_call([node | rest], mod, fun, args, opts) do
    case do_call_node(node, mod, fun, args, opts) do
      {:error, :malla_service_not_available} ->
        name = Malla.get_service_name(mod)

        case rest do
          [] ->
            Logger.warning("Service '#{name}' not available at #{node}")

          _ ->
            Logger.warning("Service '#{name}' not available at #{node}, trying next")
        end

        do_call(rest, mod, fun, args, opts)

      other ->
        other
    end
  end

  # https://erlang.org/doc/man/erpc.html#call-4
  defp do_call_node(node, mod, fun, args, opts) do
    try do
      case Keyword.get(opts, :timeout, @rpc_timeout) do
        0 ->
          :erpc.cast(node, mod, fun, args)

        timeout ->
          # Logger.debug("CALL RPC REMOTE #{inspect({node, mod, fun, args, timeout})}")
          result = :erpc.call(node, mod, fun, args, timeout)
          # Logger.debug("RPC REMOTE RESULT #{inspect result}")
          result
      end
    rescue
      e ->
        text = Exception.format(:error, e, __STACKTRACE__)
        Logger.warning("MallaNode RPC Exception: #{inspect(e)} #{text}")
        {:error, {:malla_rpc, {e, text}}}
    catch
      :exit, do_exit ->
        Logger.warning("MallaNode RPC CATCH: #{inspect(do_exit)}")
        {:error, {:malla_rpc, {do_exit, inspect(do_exit)}}}
    end
  end

  @doc """
    Launches a request to call a callback defined on a local or remote service.

    It works by using `call/4` but calling special function `c:Malla.Service.Interface.malla_cb_in/3`,
    that is always defined in remote services.

    This function will change process group (so that IO is not redirected to caller),
    set _service id_ and call malla callback `c:Malla.Plugins.Base.service_cb_in/3`;
    this, by default, will simply call the requested callback.

    If `:timeout` is set to zero, call will be asynchronous.
  """

  @spec call_cb(Malla.id(), atom, list, [call_opt]) :: call_result()

  def call_cb(srv_id, fun, args, opts \\ []),
    do: call(srv_id, :malla_cb_in, [fun, args, opts], [{:service_id, srv_id} | opts])

  @doc """
    Similar to `call_cb/4` but sends the call to all nodes implementing the requested service.

    It returns all responses from all nodes. If `:timeout` is set to zero, calls will be asynchronous.
  """

  @spec call_cb_all(Malla.id(), atom, list, [call_opt]) :: [call_result]

  def call_cb_all(srv_id, fun, args, opts \\ []) do
    for node <- get_nodes(srv_id) do
      call_cb(srv_id, fun, args, [
        {:service_id, srv_id},
        {:nodes, [node]} | opts
      ])
    end
  end

  @doc false
  @spec cb_all_sync(Malla.id(), atom, list, [call_opt]) :: [call_result]
  def cb_all_sync(srv_id, fun, args, opts \\ []), do: call_cb_all(srv_id, fun, args, opts)

  ## ===================================================================
  ## LEGACY
  ## ===================================================================

  @spec cb(Malla.id(), atom, list, [call_opt]) :: call_result()

  @doc false
  def cb(srv_id, fun, args, opts \\ []),
    do: call(srv_id, :cb, [fun, args, opts], [{:service_id, srv_id} | opts])

  ## ===================================================================
  ## GenServer
  ## ===================================================================

  @doc false
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @typedoc false
  @type t :: %State{
          # current service_info
          services_info: %{pid() => {Malla.id(), meta: service_info()}},
          # all detected ids, ever
          services_id: [Malla.id()]
        }

  defstruct [:services_info, :services_id]

  @impl true
  @doc false
  def init([]) do
    :ok = :pg.join(Malla.Services2, Malla.Node, self())
    # Subscribe to node connection/disconnection events
    :ok = :net_kernel.monitor_nodes(true)
    state = %State{services_info: %{}, services_id: []}
    Process.send_after(self(), :check_services, 1000)
    {:ok, state}
  end

  @impl true
  @doc false
  def handle_call(:get_services, _from, %State{} = state) do
    {:reply, Map.take(state, [:services_info, :services_id]), state}
  end

  @impl true
  @doc false
  def handle_cast({:set_service_info, true, info}, %State{} = state) do
    %State{services_info: services_info} = state
    %{id: srv_id, pid: pid, meta: meta} = info
    _ref = if Map.get(services_info, pid) == nil, do: Process.monitor(pid)
    services_info = Map.put(services_info, pid, {srv_id, meta})
    maybe_make_module(srv_id, meta)
    # recalculate to randomize services
    state = compute_services(%State{state | services_info: services_info})
    {:noreply, state}
  end

  def handle_cast({:set_service_info, false, info}, %State{} = state) do
    %State{services_info: services_info} = state
    %{pid: pid} = info
    services_info = Map.delete(services_info, pid)
    # recalculate to randomize services
    state = compute_services(%State{state | services_info: services_info})
    {:noreply, state}
  end

  @impl true
  @doc false
  def handle_info(:check_services, state) do
    check_services()
    Process.send_after(self(), :check_services, @check_services_time)
    {:noreply, state}
  end

  def handle_info({:nodeup, node}, state) do
    Logger.info("Node connected: #{inspect(node)}, triggering service discovery")
    check_services()
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.info("Node disconnected: #{inspect(node)}")
    # Service discovery will clean up on next periodic check
    # or immediately via DOWN messages for monitored processes
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{} = state) do
    %State{services_info: services_info} = state

    case Map.get(services_info, pid) do
      nil ->
        # It already reported as down
        {:noreply, state}

      {srv_id, _meta} ->
        Logger.notice("Remote service #{inspect(srv_id)} is down on #{inspect(node(pid))}")
        services_info = Map.delete(services_info, pid)
        state = %State{state | services_info: services_info}
        {:noreply, compute_services(state)}
    end
  end

  ## ===================================================================
  ## Internal
  ## ===================================================================

  # @doc "Updates local info for a service"
  # @spec update_service_info_local({running :: boolean, info :: service_info}) :: :ok
  # def update_service_info_local({running, info}),
  #   do: GenServer.cast(__MODULE__, {:set_service_info, running, info})

  @doc false
  # Called from a local Server when its config has changed, so we can update all
  # instances on the network immediately, without waiting for the next update
  @spec update_service_info_global({running :: boolean(), info :: service_info_message()}) :: :ok

  def update_service_info_global({running, info}) do
    for pid <- :pg.get_members(Malla.Services2, Malla.Node),
        do: GenServer.cast(pid, {:set_service_info, running, info})

    :ok
  end

  # For each service instance detected on the network,
  # launches a process to ask for status and cast back
  # Each service can only last for the duration of the call

  defp check_services() do
    fun = fn pid ->
      case Server.get_running_info(pid) do
        {:ok, {is_running, info}} ->
          GenServer.cast(__MODULE__, {:set_service_info, is_running, info})

        _ ->
          :ok
      end
    end

    # Calls :pg.get_members(Malla.Services2, :all) to get all services
    Server.get_all_global_pids() |> Enum.each(fn pid -> spawn(fn -> fun.(pid) end) end)
  end

  # Finds running services and stores pid and vsn in config to
  # be retrieved by get_instances/1
  @spec compute_services(%State{}) :: %State{}
  defp compute_services(%State{} = state) do
    %State{services_info: services_info, services_id: services_id} = state

    # lets suppose all previous detected services are now empty (no implementations on network)
    base = for id <- services_id, do: {id, []}, into: %{}

    data =
      services_info
      |> Enum.reduce(base, fn {pid, {srv_id, meta}}, acc ->
        prev = Map.get(acc, srv_id, [])
        Map.put(acc, srv_id, [{node(pid), Map.put(meta, :pid, pid)} | prev])
      end)
      |> Enum.map(fn {id, list} ->
        # if the local node is on the list, put it the first
        list =
          case List.keytake(list, node(), 0) do
            {{_node, meta}, rest} -> [{node(), meta} | rand(rest)]
            nil -> rand(list)
          end

        {id, list}
      end)

    services_id =
      for {srv_id, list} <- data do
        Malla.Config.put(__MODULE__, {:service_running_data, srv_id}, list)
        srv_id
      end

    %State{state | services_id: services_id}
  end

  defp rand([]), do: []
  defp rand([single]), do: [single]
  defp rand(list), do: Enum.shuffle(list)

  # Checks if a dynamic module for the service exists and matches the provided callbacks. If not, creates or updates the module.
  @spec maybe_make_module(Malla.id(), map()) :: :ok

  _ = """
   For each detected service, we create a module called 'Malla.<SrvId>'
   On it, a function is added for each callback defined in remote service.

   When calling this functions, if no caller service_id is detected,
   a call will be made to Malla.Node.cb/3

   If a service is detected, callback service_cb_out/4 will be called.
   Default implementation is again calling Malla.Node.cb/4
  """

  defp maybe_make_module(srv_id, %{callbacks: callbacks}) do
    if function_exported?(srv_id, :__malla_node_callbacks, 0) do
      # Module was already created by us
      case apply(srv_id, :__malla_node_callbacks, []) do
        ^callbacks -> :ok
        _ -> do_make_module(srv_id, callbacks)
      end
    else
      if not function_exported?(srv_id, :__info__, 1) do
        # let's make sure the original module is not there
        # because the service is running locally
        do_make_module(srv_id, callbacks)
      end
    end
  end

  # still not implemented for this module
  defp maybe_make_module(_srv_id, _), do: :ok

  # Dynamically creates a module `<SrvId>` with proxy functions for each callback, routing calls to remote services.
  @spec do_make_module(Malla.id(), [{atom(), non_neg_integer()}]) ::
          {:module, module(), binary(), term()}

  defp do_make_module(srv_id, callbacks) do
    contents =
      quote do
        # @service_id unquote(srv_id)
        @callbacks unquote(Macro.escape(callbacks))
        def __malla_node_callbacks(), do: @callbacks
        unquote(Malla.Node.make_callbacks())
      end

    :code.purge(srv_id)
    :code.delete(srv_id)
    Module.create(srv_id, contents, Macro.Env.location(__ENV__))
  end

  @doc false
  # Macro that generates callback functions in dynamic modules, handling routing to local or remote services based on caller context.
  def make_callbacks() do
    quote bind_quoted: [] do
      for {name, arity} <- @callbacks do
        args = Macro.generate_arguments(arity, __MODULE__)

        def unquote(name)(unquote_splicing(args)) do
          Malla.remote(__MODULE__, unquote(name), unquote(args))
        end
      end
    end
  end

  @doc false
  # Macro that generates stub callback functions that always return {:error, :malla_service_not_available}
  def make_stub_callbacks() do
    quote bind_quoted: [] do
      for {name, arity} <- @callbacks do
        args = Macro.generate_arguments(arity, __MODULE__)

        def unquote(name)(unquote_splicing(args)) do
          {:error, :malla_service_not_available}
        end
      end
    end
  end

  @doc """
  Precompiles stub modules for services defined in application configuration.

  Reads the `:precompile` config key from `:malla` application and creates
  stub modules for each service. These stubs will return `{:error, :malla_service_not_available}`
  until the actual service is discovered.

  Configuration format:
      config :malla,
        precompile: [
          MyService: [callback1: 0, callback2: 3]
        ]
  """
  @spec precompile_stubs() :: :ok
  def precompile_stubs() do
    case Malla.Application.get_env(:precompile) do
      nil ->
        :ok

      precompile_list when is_list(precompile_list) ->
        for {srv_id, callbacks} <- precompile_list do
          do_make_stub_module(srv_id, callbacks)
        end

        :ok
    end
  end

  # Dynamically creates a stub module `<SrvId>` with proxy functions that return errors
  @spec do_make_stub_module(Malla.id(), [{atom(), non_neg_integer()}]) ::
          {:module, module(), binary(), term()}

  defp do_make_stub_module(srv_id, callbacks) do
    contents =
      quote do
        @callbacks unquote(Macro.escape(callbacks))
        def __malla_node_callbacks(), do: @callbacks
        unquote(Malla.Node.make_stub_callbacks())
      end

    :code.purge(srv_id)
    :code.delete(srv_id)
    Module.create(srv_id, contents, Macro.Env.location(__ENV__))
  end
end
