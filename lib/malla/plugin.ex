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

defmodule Malla.Plugin do
  @moduledoc """
  Defines the core behavior for a Malla plugins.

  By `use Malla.Plugin`, a module is transformed into a plugin that can be
  _inserted_ into a `Malla.Service`. `Malla.Plugin` enables the creation of reusable,
  composable modules that provide or modify service behavior through compile-time callback chaining.

  This module also provides a set of callbacks that will have a default implementation
  if not overriden in your plugin module.

  For comprehensive documentation, please see the guides:
  - **[Plugins](guides/04-plugins.md)**: For an overview of creating and using plugins.
  - **[Callbacks](guides/05-callbacks.md)**: For understanding the callback chain.
  - **[Lifecycle](guides/06-lifecycle.md)**: For hooking into the service lifecycle.
  """

  @type id() :: Malla.id()

  ## ===================================================================
  ## Plugin Callbacks
  ## ===================================================================

  @type start_opt ::
          {:children, child_spec()}
          | Supervisor.option()
          | Supervisor.init_option()

  @type child_spec() ::
          Supervisor.child_spec()
          | {module(), term()}
          | module()
          | (old_erlang_child_spec :: :supervisor.child_spec())

  @doc """
  Optional callback called before service's start.
  It allows the plugin to check and, if needed, modify the config.

  See [Configuration](guides/07-configuration.md).

  Top level plugins are called first, so they could update the config
  for other plugins they declared as dependants.
  """
  @callback plugin_config(Malla.id(), config :: keyword) ::
              :ok | {:ok, config :: keyword} | {:error, term()}

  @doc """
  Optional callback called during service's start.

  Plugins will be started on service init, starting with lower-level plugins
  up to the service itself (that is also a Plugin). See [Lifecycle](guides/06-lifecycle.md) for details.

  Plugin can return a child specification, in this case a `Supervisor` will be
  started with the specified children.

  The service will monitor this supervisor, and, if it fails, the whole service
  will be marked as 'failed' and we will retry to start it, calling this
  function again.
  """
  @callback plugin_start(Malla.id(), config :: keyword) ::
              :ok | {:ok, [start_opt]} | {:error, term()}

  @type updated_opts :: {:restart, boolean}

  @doc """
  Optional callback called when merging configuration updates.

  This callback is invoked during service initialization (when runtime config
  is merged with static config) and when `Malla.Service.reconfigure/2` is used.

  By default, if a plugin doesn't implement this callback, configurations are
  deep-merged automatically. Implement this callback when you need custom merge
  logic for your plugin's configuration keys.

  Top-level plugins (service itself, then declared plugins) are called first,
  allowing higher-level plugins to process configuration before lower-level ones.
  """
  @callback plugin_config_merge(Malla.id(), old_config :: keyword, update :: keyword) ::
              :ok | {:ok, merged_config :: keyword} | {:error, term()}

  @doc """
  Optional callback called after service's reconfiguration.
  (See `Malla.Service.reconfigure/2`).
  You are presented with _old_ and _new_ config, and you have the chance
  to restart the plugin.

  Lower level plugins are called first.
  """

  @callback plugin_updated(
              Malla.id(),
              old_config :: keyword,
              new_config :: keyword
            ) ::
              :ok | {:ok, [updated_opts]} | {:error, term()}

  @doc """
  Optional callback called if service needs to 'stop' this plugin.

  This can happen if we mark the service as _inactive_. Top-level plugins
  will be stopped first starting with the service itself (that is also a Plugin),
  up to lower level plugins in order.

  It can also happen if this plugin is removed from the service.

  After calling this function, service will stop the started children supervisor,
  if it was defined and it is already running.
  """
  @callback plugin_stop(Malla.id(), config :: keyword) :: :ok | {:error, term()}

  @doc """
  Optional **compile-time** callback that injects code into the service module.

  Unlike the other plugin callbacks, `plugin_module/1` is invoked while the
  service module is being compiled (via a `@before_compile` hook), not at
  runtime. For each plugin in the service's `t:Malla.Service.t/0` plugin chain,
  if `plugin_module/1` is exported, its return value (a quoted expression) is
  spliced into the body of the service module.

  This allows a plugin to generate functions, module attributes, or even
  nested submodules that become part of the service module itself,
  parameterized by the service's compile-time data: `id`, `plugin_chain`,
  static `config`, the resolved `callbacks` map, etc.

  The callback is invoked once per service compilation, in plugin chain order
  (top-level plugins first, `Malla.Plugins.Base` last). It runs after the
  callback dispatch logic has been generated, so `service.callbacks` is fully
  populated.

  Because the injected code lives on the service module, it is visible across
  the cluster through the same virtual-module mechanism used for remote calls.

  > #### Use sparingly {: .warning}
  >
  > Code injection makes the service module's surface area depend on which
  > plugins were compiled into it, which can be surprising to readers and
  > harder to trace than ordinary `defcb` callbacks or plugin functions.
  > Reach for `plugin_module/1` only when the desired behavior cannot be
  > expressed as a normal callback or helper — typical cases are generating
  > a function whose body must close over compile-time data (the service
  > `id`, the resolved `callbacks` map, etc.) or building a nested submodule
  > under the service.
  >
  > Plugins that use `plugin_module/1` **must** document, in their own
  > `@moduledoc`, exactly what is injected into the service module: the
  > names and arities of any generated functions, any module attributes,
  > and any nested submodules. Without this, users of the plugin have no
  > way to know which symbols on their service module came from where.

  ## Example

      defmodule MyApp.MetricsPlugin do
        use Malla.Plugin

        def plugin_module(service) do
          prefix = "malla." <> Atom.to_string(service.id)

          quote do
            def metric_prefix, do: unquote(prefix)
          end
        end
      end

  After the service compiles, `MyService.metric_prefix/0` is a regular
  function on the service module.
  """
  @callback plugin_module(service :: Malla.Service.t()) :: Macro.t()

  @optional_callbacks plugin_config: 2,
                      plugin_config_merge: 3,
                      plugin_start: 2,
                      plugin_updated: 3,
                      plugin_stop: 2,
                      plugin_module: 1

  @doc """
  Macro for defining plugin callbacks.

  Callbacks will appear at service's module and
  will participate in the callback chain.

  A Malla callback can return any of the following:

  * `:cont`: continues the call to the next function in the call chain
  * `{:cont, [:a, b:]}`: continues the call, but changing the parameters used for the next call
    in chain. The list of the array must fit the number of arguments.
  * `{:cont, :a, :b}`: equivalent to {:cont, [:a, :b]}
  * _any_: any other response stops the call chain and returns this value to the caller
  """

  defmacro defcb(ast, do: block) do
    {f, args} =
      case ast do
        {:when, _, [{f, _, args} | _]} -> {f, args}
        {f, _, args} -> {f, args}
      end

    arity = if args, do: length(args), else: 0

    quote do
      @plugin_callbacks {unquote(f), unquote(arity)}
      @doc false
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

  ## ===================================================================
  ## Use macro
  ## ===================================================================

  @typedoc """
  Options for configuring a service when using `Malla.Plugin`.

  Options include:
    * `:plugin_deps` - Declares this plugin _depends_ on these other plugins.
      Optional plugins are included only if they can be found in the source code.

      For example:
      `use Malla.Plugin, plugin_deps: [Plugin1, {Plugin2, optional: true}]`

      This plugin will be marked as dependant on `Plugin1` and `Plugin2`,
      meaning that they will be inserted first in the plugin chain list, so:
      - they will be started first, before this plugin.
      - callbacks implemented by all will reach first our plugin, then Plugin1 and Plugin2.
      - since Plugin2 is marked as optional, if it is not found, it is not included in the list.

    * `:group` - Declares plugin _group_.
      All plugins belonging to the same 'group' are added a dependency on the
      previous plugin in the same group

      For example: , so for example, if we define in our service
      `use MallaService, plugins: [PluginA, PluginB, PluginC]`

      If they all declare the same group, PluginB will depend on Plugin A and PluginC will depend on PluginB,
      so they will be started in the exact order PluginA -> PluginB -> PluginC.
      Callbacks will call first PluginC, then B and A.
  """

  @type use_opt() ::
          {:plugin_deps, [module | {module, [{:optional, boolean}]}]}
          # sent to remotes to decide usage based on version
          | {:group, atom}

  @doc """
  Macro that transforms a module into a Malla plugin.

  This macro inserts required functions, implements plugin callbacks and
  registers Malla callbacks

  See `t:use_opt/0` for configuration options.
  """
  @spec __using__([use_opt]) :: Macro.t()
  defmacro __using__(opts) do
    quote do
      @plugin_use_spec unquote(opts)
      @before_compile Malla.Plugin

      plugins =
        Keyword.get(@plugin_use_spec, :plugin_deps, [])
        |> Enum.reduce(
          [],
          fn
            {plugin, list}, acc -> if list[:optional], do: acc, else: [plugin | acc]
            plugin, acc -> [plugin | acc]
          end
        )

      @plugins plugins

      @doc false
      def plugin_use_spec, do: @plugin_use_spec

      # imports macro defcb and functions from this module
      import unquote(__MODULE__), only: [defcb: 2, defcallback: 2]
      Module.register_attribute(__MODULE__, :plugin_callbacks, accumulate: true, persist: true)
      Malla.Plugin.plugin_common()
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    plugins = Module.get_attribute(env.module, :plugins)

    {:__block__, [],
     for plugin <- plugins do
       {:require, [context: Elixir], [{:__aliases__, [alias: false], [plugin]}]}
     end}
  end

  @doc false
  defmacro plugin_common() do
    quote location: :keep do
      # imports macro defcb and functions from this module
      @behaviour unquote(__MODULE__)

      @doc false
      def plugin_config(_srv_id, _config), do: :ok

      @doc false
      def plugin_config_merge(_srv_id, _old_config, _update), do: :ok

      @doc false
      def plugin_start(_srv_id, _config), do: :ok

      @doc false
      def plugin_stop(_srv_id, _config), do: :ok

      @doc false
      def plugin_updated(_srv_id, _old_config, _new_config), do: :ok

      defoverridable plugin_config: 2,
                     plugin_config_merge: 3,
                     plugin_start: 2,
                     plugin_stop: 2,
                     plugin_updated: 3
    end
  end

  ## ===================================================================
  ## Util
  ## ===================================================================

  # require Logger

  # @type merge_opt :: {:deep_merge, boolean}

  # @doc """
  # Utility function for plugins to merge config updates.
  # It is intended to be used from service_merge_config/2 callback.

  # During a reconfiguration, callback `service_merge_config/2` will be
  # called, and plugins should use it to merge updates on the main config
  # of the service.

  # Later on, plugin callbacks `plugin_updated/4` will be called,
  # where any plugin can decide on restart itself.

  # If key is present in update, it will be merged to previous config for
  # that same key in config. If new merged config changes anything:

  # - config will be updated with new values under 'key'
  # - related 'key' in update is deleted so that it won't affect
  #   other plugins in chain, or, of ot reaches default implementation,
  #   prints a warning about unhandled update

  # If the plugin is able to manage multiple instances of 'key', it should use
  # merge_config_multi/4 instead

  # If you use opion deep_merge: true, the keyword merge will go deep

  # """

  # @spec merge_config(keyword, atom, keyword, [merge_opt]) ::
  #         :cont | {:cont, keyword, keyword} | {:error, term}

  # def merge_config(config, key, update, opts \\ []) do
  #   old = Keyword.get_values(config, key)
  #   new = Keyword.get_values(update, key)

  #   case {old, new} do
  #     {_, []} ->
  #       # update does not include any 'key'
  #       :cont

  #     {[], [new]} ->
  #       # update includes 'key', but base config did not, simply add it
  #       config = Keyword.put(config, key, new)
  #       update = Keyword.delete(update, key)
  #       {:cont, config, update}

  #     {[old], [new]} ->
  #       case do_merge(old, new, opts) do
  #         ^old ->
  #           {:cont, config, Keyword.delete(update, key)}

  #         merged ->
  #           config = Keyword.put(config, key, merged)
  #           update = Keyword.delete(update, key)
  #           {:cont, config, update}
  #       end

  #     {_old_list, _new_list} ->
  #       {:error, {:multi_not_allowed, key}}
  #   end
  # end

  # @doc """
  # Utility function for plugins to merge config updates, for
  # plugins that are able to manage multiple instances of 'key'
  # It is intended to be used from service_merge_config/2 callback.

  #   Use merge_config/4 instead for plugins than manage only first 'key' in config

  # This function will manage following cases:

  # * It is able to update 'key' entries individually. It is expected that
  #   each entry will have a 'name' entry, also in the update. In other case,
  #   name will be "default" for first, "default-1" for next one, etc.
  #   If a previous entry in config under 'key' is
  #   found with same name, it is merged with new config and same name

  # * In the previous case, if special entry "$delete": true is found in the update,
  #   the whole entry is deleted instead of updated

  # * If no previous entry is found with same name, a new one is added

  # If any change is detected, config is updated and key is removed from update.
  # See merge_config/4 for details.

  #  If you use opion deep_merge: true, the keyword merge will go deep
  # """

  # @spec merge_config_multi(keyword, atom, keyword, [merge_opt | {:default_name, String.t()}]) ::
  #         {:cont, keyword, keyword}

  # def merge_config_multi(config, key, update, opts \\ []) do
  #   old_list = Keyword.get_values(config, key)
  #   new_list = Keyword.get_values(update, key) |> add_default_names(opts)

  #   case do_maybe_reconfig_multi(old_list, new_list, opts) do
  #     ^old_list ->
  #       {:cont, config, Keyword.delete(update, key)}

  #     new_list ->
  #       config = Keyword.delete(config, key)
  #       config = config ++ for(data <- new_list, do: {key, data})
  #       update = Keyword.delete(update, key)
  #       {:cont, config, update}
  #   end
  # end

  # defp do_maybe_reconfig_multi(base_list, [], _opts), do: base_list

  # defp do_maybe_reconfig_multi(base_list, [new | rest], opts) do
  #   def_name = Keyword.get(opts, :default_name, "default")
  #   name = Keyword.get(new, :name, def_name)
  #   get_name = &Keyword.get(&1, :name, def_name)

  #   if Keyword.get(new, :"$delete") do
  #     base_list = for t <- base_list, get_name.(t) != name, do: t
  #     do_maybe_reconfig_multi(base_list, rest, opts)
  #   else
  #     case Enum.find(base_list, &(get_name.(&1) == name)) do
  #       nil ->
  #         # old list didn't have any entry with this name, let's add it
  #         do_maybe_reconfig_multi(base_list ++ [new], rest, opts)

  #       old ->
  #         merged = do_merge(old, new, opts)
  #         base_list = for t <- base_list, get_name.(t) != name, do: t
  #         do_maybe_reconfig_multi(base_list ++ [merged], rest, opts)
  #     end
  #   end
  # end

  # defp add_default_names(list, opts, pos \\ 0, acc \\ [])

  # defp add_default_names([], _opts, _pos, acc), do: Enum.reverse(acc)

  # defp add_default_names([next | rest], opts, pos, acc) do
  #   def_name = Keyword.get(opts, :default_name, "default")
  #   def_name = if pos == 0, do: def_name, else: "#{def_name}_#{pos}"
  #   name = Keyword.get(next, :name, def_name)
  #   next = Keyword.put(next, :name, name)
  #   add_default_names(rest, opts, pos + 1, [next | acc])
  # end

  # # defp do_msg(plugin, msg) do
  # #   srv_id = Malla.get_service_id!()
  # #   service = Malla.get_service_name(srv_id)
  # #   plugin_s = Malla.get_service_name(plugin)
  # #   Logger.notice("Config for '#{service}' (#{plugin_s}) " <> msg)
  # # end

  # defp do_merge(base, update, opts) do
  #   if opts[:deep_merge],
  #     do: Malla.Util.keyword_merge(base, update),
  #     else: Keyword.merge(base, update)
  # end

  # @doc """
  #   Utility functions for plugins to restart if config has changed

  #   It is intented to be called from plugin_update/4 callback.
  #   It will extract key from both old and new config, and, if they
  #   are different, it will return `{:ok, restart: true}`.

  #   Otherwise it will return  `:ok`

  # """
  # @spec maybe_restart(keyword, atom, keyword) :: :ok | {:ok, keyword}

  # def maybe_restart(old_config, key, new_config) do
  #   old = Keyword.get_values(old_config, key)
  #   new = Keyword.get_values(new_config, key)

  #   if old == new do
  #     :ok
  #   else
  #     {:ok, restart: true}
  #   end
  # end
end
