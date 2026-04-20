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

defmodule Malla.Service do
  @moduledoc """
  Defines the core behavior for a Malla service.

  `Malla.Service` is the foundation of the Malla framework. By `use Malla.Service`,
  a module is transformed into a service with features like automatic cluster
  discovery, a plugin-based architecture, and compile-time optimized callback chains.

  When you use this module at your service module, a number of utility functions are
  inserted into your module. They are documented at `Malla.Service.Interface`.

  For comprehensive documentation, please see the guides:
  - **[Services](guides/03-services.md)**: For an overview of creating services.
  - **[Plugins](guides/04-plugins.md)**: For extending services with plugins.
  - **[Callbacks](guides/05-callbacks.md)**: For understanding the callback chain.
  - **[Lifecycle](guides/06-lifecycle.md)**: For the service lifecycle.
  - **[Configuration](guides/07-configuration.md)**: For configuring services.
  - **[Storage](guides/10-storage.md)**: For data storage options.
  """

  # use Malla.Plugin
  # require Logger
  # use GenServer

  @type id :: Malla.id()
  @type class :: Malla.class()

  @type admin_status :: :active | :pause | :inactive

  @type running_status ::
          :starting | :running | :pausing | :paused | :stopping | :stopped | :failed

  @type t ::
          %__MODULE__{
            id: id,
            class: class,
            vsn: String.t(),
            # Defined plugins
            plugins: [module],
            # if true, service will be visible globally in the cluster
            global: boolean,
            # if true, service starts in 'paused' state and no children supervisors are started yet
            start_paused: boolean,
            # if true, suppress messages to console about service start/stop/reconfigure
            silent: boolean,
            wait_for_services: [id],
            # Chain of plugins, in the order they will be called (first top-level)
            plugin_chain: [module],
            config: Keyword.t(),
            # List of callbacks exported by all plugins, and the list of plugins
            # that implement each, in the order they should be called
            callbacks: %{{atom, integer} => {atom, [module()]}}
          }

  defstruct id: nil,
            class: nil,
            vsn: "",
            plugins: [],
            global: false,
            start_paused: false,
            silent: false,
            wait_for_services: [],
            plugin_chain: [],
            config: [],
            callbacks: %{}

  @type service_info() :: %{
          id: Malla.id(),
          # class: Malla.class(),
          vsn: Malla.vsn(),
          hash: pos_integer(),
          admin_status: admin_status,
          running_status: running_status,
          last_status_time: pos_integer,
          last_status_reason: term,
          last_error: term,
          last_error_time: pos_integer | nil,
          # plugins: %{module() => nil | {pid | :none, keyword}},
          pid: pid(),
          node: node(),
          callbacks: [{atom, pos_integer}]
        }

  ## ===================================================================
  ## API - Management
  ## ===================================================================

  @doc """
  Starts a new service instance.

  If a non-empty config is provided, it will be deep-merged with the compile-time config.
  Plugins can customize this behavior via `c:Malla.Plugin.plugin_config_merge/3`.

  See [Lifecycle](guides/06-lifecycle.md) for deatils
  """

  @spec start_link(Malla.id(), keyword) :: {:ok, pid} | {:error, term}

  def start_link(srv_id, config),
    do: GenServer.start_link(Malla.Service.Server, [srv_id, config], name: srv_id)

  @doc """
    Stops a service instance.

    If the service was started under a supervisor, this could try to restart it.
    If you used service module's `c:Malla.Service.Interface.child_spec/1`,
    restart would be set to `:transient` so the supervisor will not restart it.

  """
  @spec stop(Malla.id()) :: :ok | {:error, any}
  def stop(srv_id),
    do: GenServer.call(srv_id, :stop, :infinity)

  @doc """
  Get current service status.

  This is implemented as a call to the service's GenServer.
  """
  @spec get_service_info(Malla.id() | pid, timeout) :: {:ok, service_info} | {:error, term}

  def get_service_info(srv_id, timeout \\ 5000),
    do: GenServer.call(srv_id, :get_service_info, timeout)

  @doc """
  Get current running status.

  This is cached so it is very fast, but it could be slightly outdated
  on service status changes.
  """

  @spec get_config(Malla.id()) :: keyword() | :unknown
  def get_config(srv_id) do
    if is_pid(Process.whereis(srv_id)) do
      key = srv_id.__service__(:config_key)
      :persistent_term.get(key, :unknown)
    else
      :unknown
    end
  end

  @spec get_status(Malla.id()) :: running_status | :unknown
  def get_status(srv_id) do
    if is_pid(Process.whereis(srv_id)) do
      key = srv_id.__service__(:status_key)
      :persistent_term.get(key, :unknown)
    else
      :unknown
    end
  end

  @doc """
  Sets current admin status for the service.

  See above for a detailed description of each status.
  """
  @spec set_admin_status(Malla.id(), admin_status, atom) :: :ok | {:error, term}
  def set_admin_status(srv_id, admin_status, reason \\ :none)
      when admin_status in [:active, :pause, :inactive],
      do: GenServer.call(srv_id, {:set_admin_status, admin_status, reason}, :infinity)

  @doc """
    Updates config for the service **at runtime**.

    This is a very powerful function, and all used plugins
    need to support it in order to work properly (unless they are
    not affected by changes).

    The new configuration is deep-merged over the previous one by default.
    Plugins can customize merge behavior via `c:Malla.Plugin.plugin_config_merge/3`.

    After the update we will call `c:Malla.Plugin.plugin_updated/3` for existing plugins.
    If a plugin does not implement it, it won't notice the update.
  """
  def reconfigure(srv_id, update),
    do: GenServer.call(srv_id, {:reconfigure, update}, :infinity)

  @doc """
    Removes a plugin from the service **at run-time**.

    Plugin will be removed from plugins chain, and children will be stopped.

    It will also recalculate the whole callback chain,
    according to callbacks defined in this new plugin.

    Dispatch module will be recompiled, so new callback chain
    is available immediately.
  """

  @spec del_plugin(Malla.id(), module()) :: :ok | {:error, term}

  def del_plugin(srv_id, plugin),
    do: GenServer.call(srv_id, {:del_plugin, plugin}, :infinity)

  @doc """
    Adds a new plugin to the service **at run-time**.

    New plugin will be added to the callback chain, taking into
    account any declared dependency, and starting any declared children.

    It will also recalculate the whole callback chain,
    according to callbacks defined in this new plugin.

    Dispatch module will be recompiled, so new callback chain
    is available immediately.

    Options:

    - `:config` - Optional keyword list of configuration to merge when adding the plugin.
    If provided, the config will be merged using the `c:Malla.Plugin.plugin_config_merge/3`.
  """

  @spec add_plugin(Malla.id(), module(), keyword) :: :ok | {:error, term}
  def add_plugin(srv_id, plugin, opts \\ []),
    do: GenServer.call(srv_id, {:add_plugin, plugin, opts}, :infinity)

  ## ===================================================================
  ## API - Storage
  ## ===================================================================

  @doc """
  Gets a value from service's store table.

  See [Storage](guides/10-storage.md) for details.
  """
  @spec get(id, term, term) :: term
  def get(srv_id, key, default \\ nil) do
    case :ets.lookup(srv_id, key) do
      [{_, value}] -> value
      [] -> default
    end
  end

  @doc """
  Inserts a value in service's store table.

  See [Storage](guides/10-storage.md) for details.
  """
  @spec put(id, term, term) :: :ok
  def put(srv_id, key, value) do
    true = :ets.insert(srv_id, {key, value})
    :ok
  end

  @doc """
  Inserts a new value in service's store table.
  Returns false if object already exists.

  See [Storage](guides/10-storage.md) for details.
  """
  @spec put_new(id, term, term) :: true | false
  def put_new(srv_id, key, value), do: :ets.insert_new(srv_id, {key, value})

  @doc """
  Deletes a value from service's store table.

  See [Storage](guides/10-storage.md) for details.
  """

  @spec del(id, term) :: :ok
  def del(srv_id, key) do
    true = :ets.delete(srv_id, key)
    :ok
  end

  ## ===================================================================
  ## API - Info
  ## ===================================================================

  @doc """
    Function used to detect if the service is _live_.
    It returns `true` if the service is in a _live_ state (_starting_, _running_, _pausing_, _paused_, _stopped_, _stopping_).

    If the service is in _failed_ or _unknown_ state, returns `false`, and
    external caller is expected to reset this node if this keeps returning false.

    Useful in Kubernetes pod health checks.
  """
  @spec is_live?(Malla.id()) :: boolean
  def is_live?(srv_id) do
    get_status(srv_id) in [:starting, :running, :pausing, :paused, :stopped, :stopping]
  end

  @doc """
    Function used to detect if the service is _ready_.

    If the service is in _running_ status we call callback `c:Malla.Plugins.Base.service_is_ready?/0`.
    Any plugin that is not ready should return `false`, or, if it is ready, `:cont` to go to next in chain.

    For other statuses it will return `false`. Useful in Kubernetes pod health checks.

  """
  @spec is_ready?(Malla.id()) :: boolean
  def is_ready?(srv_id) do
    case get_status(srv_id) do
      status when status in [:running] -> srv_id.service_is_ready?()
      _ -> false
    end
  end

  @doc false
  def get_service(srv_id), do: GenServer.call(srv_id, :get_service)

  @doc """
  Retrieves all implementations of a callback function across plugins.

  Returns a list of `{callback_name, arity}` along the list of modules that implement it, useful for debugging or introspection.
  """

  @spec get_callbacks(Malla.id(), atom) :: [{{atom, integer}, [module]}]

  def get_callbacks(service_id, fun) do
    %{callbacks: callbacks} = apply(service_id, :service, [])
    Enum.filter(callbacks, fn {{name, _arity}, _} -> name == fun end)
  end

  ## ===================================================================
  ## API - Plugins
  ## ===================================================================

  @doc """
  Returns supervisor PID for a specific plugin children, if defined.
  """
  @spec get_plugin_sup(Malla.id(), module) :: pid() | nil
  def get_plugin_sup(srv_id, plugin),
    do: Malla.Registry.whereis({Malla.Service.Server, :plugin_sup, srv_id, plugin})

  @doc """
  Instructs to the service to restart a plugin.

  Children supervisor, if started, will be stopped, and `c:Malla.Plugin.plugin_start/2` will be
  called again.
  """
  @spec restart_plugin(Malla.id(), module) :: :ok
  def restart_plugin(srv_id, plugin), do: GenServer.cast(srv_id, {:restart_plugin, plugin})

  @doc """
  Utility function to register a name for a plugin's child, using `Malla.Registry`.

  You can use `child_whereis/3` to find it later.
  """
  @spec child_via(Malla.id(), module, term) :: {:via, module, any}
  def child_via(srv_id, plugin, name),
    do: Malla.Registry.via({__MODULE__, :child_name, srv_id, plugin, name})

  @doc """
  Gets a previously registered child with `child_via/3`
  """
  @spec child_whereis(Malla.id(), module, term) :: pid | nil
  def child_whereis(srv_id, plugin, name),
    do: Malla.Registry.whereis({__MODULE__, :child_name, srv_id, plugin, name})

  ## ===================================================================
  ## API - Drain
  ## ===================================================================

  @doc """
    Function used to prepare the node for stop.

    Callback `c:Malla.Plugins.Base.service_drain/0` is called to allow each plugin to
    clean its state, and return `:cont` if it is ready to stop, or false if it is not.

    If all plugins completed the drain, this returns `true`
    and the node can be stopped. If any returned `false`, this
    function returns `false` and the node should not be yet stopped.
  """
  @spec drain(Malla.id()) :: boolean
  def drain(srv_id), do: srv_id.service_drain()

  # @doc """
  #   Finds all local running services and tries to drain them.
  #   For each service, `drain/1` is called. If a service is successful, next one is called.

  #   Services with higher priority will be called last

  # """
  # @spec drain_all_local() :: boolean

  # def drain_all_local(),
  #   do:
  #     get_all_local()
  #     |> Enum.sort(&(&1.priority < &2.priority))
  #     |> Enum.map(& &1.id)
  #     |> drain_all()

  # defp drain_all([]), do: true

  # defp drain_all([id | rest]) do
  #   if drain(id) do
  #     Logger.notice("Service #{id} IS DRAINED")
  #     drain_all(rest)
  #   else
  #     Logger.warning("Service #{id} IS NOT DRAINED")
  #     false
  #   end
  # end

  ## ===================================================================
  ## Use macro
  ## ===================================================================

  @typedoc """
  Options for configuring a service when using `Malla.Service`.

  Options include:
    * `:class` - The service class. Any atom can be used. Not used by Malla but available in metadata.
    * `:vsn` - Version string. Not used by Malla but available in metadata.
    * `:otp_app` - If provided, configuration will be fetched from application config and merged.
    * `:global` - Whether the service is globally visible.
    * `:paused` - Whether to start in paused state.
    * `:silent` - Whether to suppress console messages about service start/stop/reconfigure.
    * `:plugins` - List of plugin modules this services _depends_ on.

  Any other key is considered configuration for the service. See [Configuration](guides/07-configuration.md).
  """

  @type use_opt() ::
          {:class, Malla.class()}
          # sent to remotes to decide usage based on version
          | {:vsn, Malla.vsn()}
          # fetch configuration from this app, key as the Service
          | {:otp_app, atom}
          # if true, it will register the service globally
          | {:global, boolean}
          # if paused is used, the service will start in 'paused' status and
          # plugins children will not yet be started
          | {:paused, boolean}
          # if true, suppress console messages about service lifecycle
          | {:silent, boolean}
          | {:plugins, [module]}
          | {atom, any}

  ## ===================================================================
  ## Service Use Macro
  ## ===================================================================

  @doc """
  Macro that transforms a module into a Malla service.

  This macro inserts required functions, sets up plugin configuration,
  registers callbacks, and prepares compile-time hooks for building
  the service structure and dispatch logic.

  See `t:use_opt/0` for configuration options.
  """
  @spec __using__([use_opt]) :: Macro.t()

  defmacro __using__(use_spec) do
    quote location: :keep do
      @behaviour Malla.Service.Interface

      require Malla.Plugin

      # Any Service is really a Plugin under the hood, so we inject basic plugin callbacks
      Malla.Plugin.plugin_common()

      import Malla.Service, only: [defcb: 2, defcallback: 2]
      Module.register_attribute(__MODULE__, :plugin_callbacks, accumulate: true, persist: true)

      @use_spec unquote(use_spec)
      @plugins Keyword.get(@use_spec, :plugins, [])

      # atoms used as fast key for persistent_term
      @status_key Module.concat(__MODULE__, MallaStatus)
      @config_key Module.concat(__MODULE__, MallaConfig)

      @impl true
      def start_link(start_ops \\ []), do: Malla.Service.start_link(__MODULE__, start_ops)

      @impl true
      def stop(), do: Malla.Service.stop(__MODULE__)

      @impl true
      def child_spec(start_ops \\ []) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [__MODULE__, start_ops]},
          restart: :transient,
          shutdown: :infinity,
          type: :worker
        }
      end

      @impl true
      def set_admin_status(status, reason \\ :none),
        do: Malla.Service.set_admin_status(__MODULE__, status, reason)

      @impl true
      def reconfigure(config), do: Malla.Service.reconfigure(__MODULE__, config)

      @impl true
      def get_config() do
        if is_pid(Process.whereis(__MODULE__)) do
          :persistent_term.get(@config_key, :unknown)
        else
          :unknown
        end
      end

      @impl true
      def get_status() do
        if is_pid(Process.whereis(__MODULE__)) do
          :persistent_term.get(@status_key, :unknown)
        else
          :unknown
        end
      end

      @doc false
      def __service__(:status_key), do: @status_key
      def __service__(:config_key), do: @config_key

      # Calls a Service callback, but first setting process global leader to :user
      # so that responses are not sent back to caller
      # It sets current module as current service in process's dictionary
      # It is called when you use Malla.Node.cb/4

      @doc false
      # TO REMOVE
      @spec cb(atom, list, keyword) :: any
      def cb(fun, args, _opts) do
        gl = Process.group_leader()
        Process.group_leader(self(), Process.whereis(:user))
        Malla.put_service_id(__MODULE__)
        res = apply(__MODULE__, fun, args)
        Process.group_leader(self(), gl)
        res
      end

      @doc false
      # NEW VERSION
      @impl true
      def malla_cb_in(fun, args, opts) do
        gl = Process.group_leader()
        Process.group_leader(self(), Process.whereis(:user))
        Malla.put_service_id(__MODULE__)
        res = apply(__MODULE__, :service_cb_in, [fun, args, opts])
        Process.group_leader(self(), gl)
        res
      end

      @before_compile {Malla.Service, :__before_compile_requires__}
      @before_compile {Malla.Service, :__before_compile_main__}
      @before_compile {Malla.Service, :__before_compile_modules__}
    end
  end

  ## ===================================================================
  ## Callback Definition Macro
  ## ===================================================================

  @doc """
  Macro for defining service callbacks.

  Transforms a function definition into a callback that can be chained
  across plugins. The original function is renamed to `{name}_malla_service` and registered
  for the callback system. At compile time, chained dispatch functions are
  generated that call implementations in dependency order, supporting
  continuation logic.

  A Malla callback can return any of the following:

  * `:cont`: continues the call to the next function in the call chain.
  * `{:cont, [:a, b:]}`: continues the call, but changing the parameters used for the next call.
    in chain. The list of the array must fit the number of arguments.
  * `{:cont, :a, :b}`: equivalent to {:cont, [:a, :b]}.
  * _any_: any other response stops the call chain a returns this value to the caller.

  See **[Callbacks](guides/05-callbacks.md)** for details.

  """
  defmacro defcb(ast, do: block) do
    {f, args} =
      case ast do
        {:when, _, [{f, _, args} | _]} -> {f, args}
        {f, _, args} -> {f, args}
      end

    arity = if args, do: length(args), else: 0
    real_name = "#{to_string(f)}_malla_service" |> String.to_atom()

    spec_args = Enum.map(args || [], fn _ -> {:any, [], Elixir} end)

    ast =
      case ast do
        {:when, meta1, [{_f, meta2, args} | rest]} ->
          {:when, meta1, [{real_name, meta2, args} | rest]}

        {_f, meta, args} ->
          {real_name, meta, args}
      end

    quote do
      @plugin_callbacks {unquote(f), unquote(arity)}
      @spec unquote(real_name)(unquote_splicing(spec_args)) :: any()
      def unquote(ast), do: unquote(block)
    end
  end

  @doc false
  # DO NOT USE THIS LEGACY VERSION
  defmacro defcallback(ast, do: block) do
    quote do
      defcb unquote(ast) do
        unquote(block)
      end
    end
  end

  # Compile-time hook that generates `require` statements for all plugins.
  # This ensures all plugin modules are compiled and available before
  # the service module is fully processed.
  @doc false
  defmacro __before_compile_requires__(env) do
    plugins = Module.get_attribute(env.module, :plugins)

    {:__block__, [],
     for plugin <- plugins do
       {:require, [context: Elixir], [{:__aliases__, [alias: false], [plugin]}]}
     end}
  end

  # Main compile-time hook that builds the service structure.
  # Creates the `Malla.Service.t` struct from use specs and callbacks,
  # sets up the MallaDispatch submodule for callback dispatching, and
  # generates the public callback functions that delegate to the dispatch.
  @doc false
  defmacro __before_compile_main__(_env) do
    quote location: :keep, bind_quoted: [] do
      callbacks = Module.get_attribute(__MODULE__, :plugin_callbacks)
      service = Malla.Service.Make.make(__MODULE__, @use_spec, callbacks)
      @service service

      alias __MODULE__.MallaDispatch

      @doc false
      def service(), do: MallaDispatch.service()

      # For all known callbacks, create a version here that simply points to Module.MallaDispatch
      # We will make sure stored service_id is correct
      for {{fun_name, arity}, _} <- service.callbacks do
        args = Macro.generate_arguments(arity, __MODULE__)

        @doc false
        def unquote(fun_name)(unquote_splicing(args)) do
          case Malla.get_service_id() do
            __MODULE__ ->
              MallaDispatch.unquote(fun_name)(unquote_splicing(args))

            other ->
              Malla.put_service_id(__MODULE__)
              res = MallaDispatch.unquote(fun_name)(unquote_splicing(args))
              Malla.put_service_id(other)
              res
          end
        end
      end

      ## ===================================================================
      ## Creation of Module.MallaDispatch
      ## ===================================================================

      defmodule MallaDispatch do
        @moduledoc false
        @dialyzer [:no_match, :no_fail_call]
        [_ | mods] = Module.split(__MODULE__) |> Enum.reverse()
        srv_id = Enum.reverse(mods) |> Module.concat()
        @service Module.get_attribute(srv_id, :service)
        @before_compile {Malla.Service, :__before_compile_dispatch__}
      end
    end
  end

  # Hook that injects callback dispatch code into MallaDispatch.
  # Calls `Malla.Service.Build.callbacks()` to generate the optimized
  # callback chaining functions based on plugin implementations.
  @doc false
  defmacro __before_compile_dispatch__(_env) do
    quote do
      unquote(Malla.Service.Build.callbacks())
    end
  end

  # Final compile-time hook that includes plugin modules.
  # For each plugin in the chain that has a `plugin_module/1` function,
  # includes the generated module code in the service module
  @doc false
  defmacro __before_compile_modules__(env) do
    service = Module.get_attribute(env.module, :service)

    {:__block__, [],
     for plugin <- service.plugin_chain do
       if Kernel.function_exported?(plugin, :plugin_module, 1) do
         plugin.plugin_module(service)
       end
     end}
  end
end
