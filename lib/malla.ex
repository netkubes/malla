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

defmodule Malla do
  @moduledoc """
  `Malla` is a comprehensive framework that simplifies the development of distributed
  services through a plugin-based architecture with compile-time callback chaining,
  automatic service discovery across nodes, and minimal "magic" to keep systems
  understandable.

  See the [Introduction guide](../../guides/01-introduction.md) for a general overview.

  ## API Overview

  ### Service Management

  - `get_service_id/0`, `get_service_id!/0` - Get current service from process dictionary.
  - `put_service_id/1` - Set service context for current process.
  - `get_service_name/1` - Get string name (cached for performance).
  - `get_service_meta/1` - Get metadata (cluster, node, host, service).

  ### Callback Invocation

  - `local/2` - Invoke local callback with service_id from process dictionary.
  - `local/3` - Invoke local callback.
  - `remote/3` - Invoke remote callback.
  - `remote/4` - Invoke remote callback with options.
  - `call/1` - Macro for syntactic sugar to invoke remote callbacks.
  - `call/2` - Macro for syntactic sugar to invoke remote callbacks with options.

  ### Utilities

  - `metric/4` - Record metric with auto-injected metadata.
  - `event/2` - Generate event with service context.
  - `authorize/3` - Authorization callback.


  ## See Also

  - `Malla.Service` - Service behavior and lifecycle.
  - `Malla.Plugin` - Plugin development guide.
  - `Malla.Tracer` - Observability instrumentation.
  - `Malla.Node` - Service discovery and RPC.
  """

  require Logger

  defmodule ServiceIdMissing do
    defexception [:message]

    @impl true
    def exception(_) do
      %ServiceIdMissing{message: "service_id is missing"}
    end
  end

  @compile {:inline, get_service_id: 0, get_service_id: 1}

  @type id :: module
  @type class :: atom
  @type vsn :: String.t()
  @type config :: list

  @type cont :: :cont | {:cont, list} | {:cont, any, any} | {:cont, any, any, any}

  @type service :: Malla.Service.t()

  @doc """
    Gets the current service ID from the process dictionary, or `nil` if not defined.

    On each callback call, called using `local/3` or `remote/4`, the service ID is always inserted in the process dictionary.
  """
  @spec get_service_id() :: id | nil
  def get_service_id() do
    case Process.get(:malla_service_id) do
      nil -> nil
      id -> id
    end
  end

  @doc """
  Tries to extract the service ID from the `:service_id` key in a map or list,
  or, if not found, from the process dictionary. See `get_service_id/0`.
  """
  @spec get_service_id(list | map) :: id | nil

  def get_service_id(map) when is_map(map) do
    case Map.get(map, :service_id) do
      nil -> get_service_id()
      id -> id
    end
  end

  def get_service_id(list) when is_list(list) do
    case Keyword.get(list, :service_id) do
      nil -> get_service_id()
      id -> id
    end
  end

  @doc """
  Tries to get the service ID from the process dictionary, or raises `Malla.ServiceIdMissing`.
  See `get_service_id/0`.
  """
  @spec get_service_id!() :: id

  def get_service_id!() do
    case get_service_id() do
      nil ->
        case Malla.Application.get_default_service_id() do
          nil ->
            raise ServiceIdMissing

          id ->
            # Logger.warning("using default service_id for #{inspect(id)} #{inspect :erlang.get()}")
            Logger.warning("using default service_id for #{inspect(id)}")
            put_service_id(id)
            id
        end

      service_id ->
        service_id
    end
  end

  @doc """
  Tries to extract the service ID from the `:service_id` key in a map or list,
  or, if not found, from the process dictionary.
  If not found, it raises `Malla.ServiceIdMissing`. See `get_service_id/0`.
  """
  @spec get_service_id!(Keyword.t() | map()) :: id()

  def get_service_id!(term) when is_list(term) or is_map(term) do
    case get_service_id(term) do
      nil ->
        get_service_id!()

      service_id ->
        service_id
    end
  end

  @doc """
    Puts a service ID into the process dictionary.

    This is used to mark the current process as belonging to this service.
    Callbacks called for a module will have it already.

    If id is `nil` or `:undefined`, the key is deleted.
  """
  @spec put_service_id(id | nil) :: id
  def put_service_id(nil), do: Process.delete(:malla_service_id)
  def put_service_id(id), do: Process.put(:malla_service_id, id)

  @doc "Returns the string version of a service ID. Cached for fast access."
  @spec get_service_name(nil | id | String.t()) :: String.t()

  def get_service_name(nil), do: ""

  def get_service_name(str) when is_binary(str), do: str

  def get_service_name(id) do
    case :persistent_term.get({:malla_service_name, id}, nil) do
      nil ->
        service_name = inspect(id)
        :persistent_term.put({:malla_service_name, id}, service_name)
        service_name

      service_name ->
        service_name
    end
  end

  @doc """
  Returns metadata about a service ID. Cached for fast access.
  - `cluster` is extracted from `:malla` application's `:malla_cluster` environment variable.
  - `node` is the current Erlang node.
  - `host` is the first part of the node name.
  - `service` uses `get_service_name/1`.
  """
  @spec get_service_meta(id) :: %{
          cluster: String.t(),
          node: String.t(),
          host: String.t(),
          service: String.t()
        }

  def get_service_meta(id) do
    case :persistent_term.get({:malla_service_meta, id}, nil) do
      nil ->
        node = Malla.Application.get_node()
        host = String.split(node, "@") |> hd()

        meta = %{
          cluster: Malla.Application.get_cluster(),
          node: node,
          host: host,
          service: get_service_name(id)
        }

        :persistent_term.put({:malla_service_meta, id}, meta)
        meta

      meta ->
        meta
    end
  end

  @doc false
  # to remove
  def callback(fun, args), do: local(fun, args)

  @doc false
  # to remove
  def callback(srv_id, fun, args), do: local(srv_id, fun, args)

  @doc """
    Invokes a service callback locally at this node.
    The service ID must be present in the process dictionary.
    See `local/3`.
  """
  @spec local(atom, list) :: any
  def local(fun, args), do: local(get_service_id!(), fun, args)

  @doc """
    Invokes a service callback locally at this node.
    Service does not need to be running, since this simply:
    * puts service ID into process dictionary.
    * calls `c:Malla.Plugins.Base.service_cb_in/3`, which, if not overridden, will
    ultimately call the indicated function.
    * sets back previous value in process dictionary, if any.
  """
  @spec local(id, atom, list) :: any

  def local(srv_id, fun, args) do
    prev_srv_id = get_service_id()

    try do
      Malla.put_service_id(srv_id)
      apply(srv_id, :service_cb_in, [fun, args, []])
    after
      if prev_srv_id != srv_id, do: put_service_id(prev_srv_id)
    end
  end

  @default_sna_retries 5
  @default_excp_retries 0
  @default_retries_sleep 1000
  @default_timeout 15000

  @doc """
    Calls a callback function defined at the home module of a local or remote service,
    using `Malla.Node.call_cb/4`. This could be a _normal_ function defined with `def` or
    a _callback function_ defined with `defcb`.

    On the remote side, the process leader will be changed to `:user` so that IO responses are not
    sent back to the caller. It will set the correct service ID in the process dictionary and call
    the callback function `c:Malla.Plugins.Base.service_cb_in/3`, which, if not overridden, will
    ultimately call the indicated function.

    * If the {:error, `malla_service_not_available`} is returned, it means `Malla.Node` could not find
      any service to process the request. The call will be retried if `sna_retries` is defined
      (default value is #{@default_sna_retries}).
      The sleep time between retries can be set with `retries_sleep_msec`, and it is #{@default_retries_sleep} by default.

      This is very convenient in situations when the remote service is not yet available,
      because it may be starting or our node could not yet discover the service.

    * If an exception is produced during the call, the call is retried only if
      `excp_retries` is defined.
      Otherwise, the error `{:error, {:malla_rpc_error, <error_data>}}` is returned. Default `excp_retries` is #{@default_excp_retries}.

      Be very careful when activating these retries, since the request could have been
      processed partially on the remote side, and you may re-execute it.

      The default timeout is #{@default_timeout} ms.

      You can instrument the call by overriding `c:Malla.Plugins.Base.service_cb_in/3`.
  """

  @type remote_opt ::
          {:timeout, pos_integer}
          | {:sna_retries, pos_integer}
          | {:excp_retries, pos_integer}
          | {:retries_sleep_msec, pos_integer}

  @spec remote(id(), atom(), [any()], [remote_opt]) :: any()

  def remote(srv_id, fun, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Malla.Node.call_cb(srv_id, fun, args, timeout: timeout) do
      {:error, :malla_service_not_available} ->
        retries = Keyword.get(opts, :sna_retries, @default_sna_retries)

        if retries > 0 do
          srv = Malla.get_service_name(srv_id)

          "error calling CB #{fun} for #{srv}: service_not_available (retries: #{retries})"
          |> Logger.warning()

          opts = Keyword.put(opts, :sna_retries, retries - 1)
          sleep = Keyword.get(opts, :retries_sleep_msec, @default_retries_sleep)
          Process.sleep(sleep)
          remote(srv_id, fun, args, opts)
        else
          {:error, :malla_service_not_available}
        end

      {:error, {:malla_rpc, {e, text}}} ->
        srv = Malla.get_service_name(srv_id)
        retries = Keyword.get(opts, :excp_retries, @default_excp_retries)

        if retries > 0 do
          "error calling CB #{fun} for #{srv}: malla_rpc_error (retries: #{retries})\n#{inspect(e)}\n#{text}"
          |> Logger.warning()

          opts = Keyword.put(opts, :excp_retries, retries - 1)
          sleep = Keyword.get(opts, :retries_sleep_msec, @default_retries_sleep)
          Process.sleep(sleep)
          remote(srv_id, fun, args, opts)
        else
          {:error, {:malla_rpc_error, {e, text}}}
        end

      other ->
        other
    end
  end

  @doc """
  Convenient macro to make remote calls more friendly.

  It calls `remote/4` with the module, function name, and arguments extracted from the given expression.

  ## Examples

      call Module.fun(:a, :b), timeout: 5000
      # Translates to: remote(Module, :fun, [:a, :b], timeout: 5000)

  """
  defmacro call({{:., _, [module, fun]}, _, args}) do
    quote do
      Malla.remote(unquote(module), unquote(fun), unquote(args))
    end
  end

  @doc """
  Convenient macro to make remote calls more friendly.

  It calls `remote/3` with the module, function name, and arguments extracted from the given expression.

  ## Examples

      call Module.fun(:a, :b)
      # Translates to: remote(Module, :fun, [:a, :b])
  """

  defmacro call({{:., _, [module, fun]}, _, args}, opts) do
    quote do
      Malla.remote(unquote(module), unquote(fun), unquote(args), unquote(opts))
    end
  end

  @doc false
  # Generates a new event.

  # It will generate a new `Malla.Event` and call `malla_event/1`.
  # By default, it only returns the same trace.
  # Plugins should implement this callback.
  @spec event(atom, [Malla.Event.event_opt()]) :: Malla.Event.t()
  def event(class, opts \\ []) do
    event = Malla.Event.make_event(class, opts)
    service_id = get_service_id!(opts)
    service_id.malla_event(event, opts)
  end

  @type metric_opt :: {:service_id, id()}

  @doc """
    Inserts a new metric value.

    It calls `:telemetry.execute/3` with the given `class`, `value` and `meta`.
    - `class`: Taken from the calling arg, but converted to a list if it is not already.
    - `value`: If it is a number, it is converted to `%{value: <number>}`.
      If it is a list, it is converted to a map.
    - `meta`: Merged with the service's metadata obtained from `get_service_meta/1`.
      The service ID must be in `opts` or the process dictionary.
  """
  @spec metric(atom | [atom], number | map | keyword, map | keyword, [metric_opt()]) :: :ok

  def metric(class, value \\ 1, meta \\ %{}, opts \\ [])

  def metric(class, value, meta, opts) when is_number(value),
    do: metric(class, %{value: value}, meta, opts)

  def metric(class, value, meta, opts) when is_list(value),
    do: metric(class, Map.new(value), meta, opts)

  def metric(class, value, meta, opts) when is_list(meta),
    do: metric(class, value, Map.new(meta), opts)

  def metric(class, data, meta, opts) when is_map(data) and is_map(meta) do
    class = if is_list(class), do: class, else: [class]
    srv_id = get_service_id(opts)
    meta = get_service_meta(srv_id) |> Map.merge(meta)
    :telemetry.execute(class, data, meta)
  end

  @type authorize_opt :: {:service_id, id()} | term

  @doc """
    Utility function to authorize a request.

    It will simply call `c:Malla.Plugins.Base.malla_authorize/3`.
    You must implement this callback in your service.
    By default it will return `{:error, :auth_not_implemented}`.
  """

  @spec authorize(term, term, [authorize_opt]) ::
          boolean | {boolean, term} | {:error, term}

  def authorize(resource, scope, opts \\ []) do
    service_id = Malla.get_service_id!(opts)
    local(service_id, :malla_authorize, [resource, scope, opts])
  end

  # defdelegate sreq(service, op, params \\ %{}, opts \\ []), to: Malla.Request
end
