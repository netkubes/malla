## -------------------------------------------------------------------
##
## Copyright (c) 2026 Erlnets Technologies
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
##
## -------------------------------------------------------------------

defmodule Malla.Service.Make do
  @moduledoc false
  # This module provides functions to build and configure Service structs from specifications,
  # including expanding plugin dependencies, resolving callback chains, and preparing services
  # for dynamic compilation in the Malla framework.
  alias Malla.Service

  # Builds a Service struct from the given service_id, use_spec keywords, and callbacks.
  # Extracts various configuration options like class, version, plugins, etc., and initializes
  # the service with default values where not specified. Then expands plugins and resolves callbacks.
  def make(service_id, use_spec, callbacks) do
    # Create the initial Service struct with fields extracted from use_spec keywords.
    # Fields like id, class, version, etc., are set directly. Config includes remaining keywords.
    %Service{
      id: service_id,
      class: Keyword.get(use_spec, :class, nil),
      vsn: Keyword.get(use_spec, :vsn, ""),
      start_paused: Keyword.get(use_spec, :paused, false),
      # wait_for_services: Keyword.get(use_spec, :wait_for_services, []),
      global: Keyword.get(use_spec, :global, false),
      silent: Keyword.get(use_spec, :silent, false),
      priority: Keyword.get(use_spec, :priority, 0),
      plugins: Keyword.get(use_spec, :plugins, []),
      config:
        Keyword.drop(use_spec, [
          :class,
          :vsn,
          :global,
          :paused,
          :silent,
          :priority,
          :wait_for_services,
          :plugins
        ])
    }
    # Expand the plugin list into a dependency-ordered chain.
    |> expand_plugins()
    # Resolve and map callbacks from the plugin chain.
    |> get_callbacks(callbacks)
  end

  ## ===================================================================
  ## Expand plugins
  ## ===================================================================

  # Takes a number of plugins, and uses their configured dependencies to
  # generate the plugin chain
  #
  # Dependencies are defined in use for example:
  # `use Malla.Plugin, plugin_deps: [Plugin1, {Plugin2, optional: true}]
  #
  # In this example, this plugin will be marked as dependant on Plugin1 and Plugin2,
  # meaning that they will be inserted first in expanded_plugins, so:
  # - they will be started first, before this plugin
  # - callbacks implemented by all will reach first our plugin, then Plugin1 and Plugin2
  # if we return 'continue'
  # - since Plugin2 is marked as optional, if it is not found, it is not included in the list
  #
  # First plugin in `plugin_chain` will always be the Service plugin, last will be Malla.Plugins.BasePlugin,
  # Callbacks will call the first plugin in list, back to the plugin that first defined it

  @spec expand_plugins(Malla.service()) :: Malla.service()
  # Expands the list of plugins into a fully resolved dependency chain.
  # Starts with the service ID and declared plugins, adds group dependencies, resolves all deps,
  # performs topological sort, filters out unused optionals, and reverses for execution order.
  def expand_plugins(%Service{id: srv_id, plugins: plugins} = service) do
    # Collect all plugins with their dependencies, separating real and optional ones.
    {all, real, optional} =
      [srv_id | plugins]
      |> add_group_deps()
      |> add_all_deps(service, [], [], [])

    # Topologically sort the plugins based on dependencies to ensure correct startup order.
    {:ok, sorted} = Malla.Service.TopSort.top_sort(declared_order(all, service))

    # Filter out optional plugins that are not actually used (not in real list).
    plugins =
      Enum.filter(sorted, fn plugin ->
        if Enum.member?(optional, plugin) and not Enum.member?(real, plugin) do
          # Logger.debug("Removing optional not-used plugin #{inspect(plugin)}")
          false
        else
          true
        end
      end)

    # Update the service with the resolved plugin chain, reversed for callback execution order.
    %Service{service | plugin_chain: Enum.reverse(plugins)}
  end

  # Orders `all` for the topological sort, which breaks ties by this order: a
  # depth-first walk from the service following `plugins:` and each plugin's
  # `plugin_deps` in the order they are declared. So among plugins that do not
  # depend on each other, the one declared first is called first, and each
  # plugin's dependencies go right below it. Plugins the walk does not reach
  # (Malla.Plugins.Base) keep their place after the others.
  defp declared_order(all, %Service{id: srv_id} = service) do
    keys = Map.new(all)
    walked = all_declared([srv_id], service, keys, []) |> Enum.reverse()
    rest = for {plugin, _deps} <- all, plugin not in walked, do: plugin
    for plugin <- walked ++ rest, do: {plugin, Map.fetch!(keys, plugin)}
  end

  defp all_declared([], _service, _keys, seen), do: seen

  defp all_declared([plugin | rest], service, keys, seen) do
    if plugin in seen or not Map.has_key?(keys, plugin) do
      all_declared(rest, service, keys, seen)
    else
      seen = all_declared(declared_deps(plugin, service), service, keys, [plugin | seen])
      all_declared(rest, service, keys, seen)
    end
  end

  defp declared_deps(srv_id, %Service{id: srv_id, plugins: plugins}), do: dep_names(plugins)

  defp declared_deps(plugin, _service) do
    case get_plugin_opts(plugin) do
      {:ok, opts} -> dep_names(Keyword.get(opts, :plugin_deps, []))
      _ -> []
    end
  end

  defp dep_names(deps), do: for(dep <- deps, do: if(is_tuple(dep), do: elem(dep, 0), else: dep))

  # Plugins can declare they 'belong' to a 'group', for example:
  # `use Malla.Plugin, group: :group1`
  #
  # All plugins in the same 'group' are chained to enforce an ordering among
  # them: each one depends on the previous plugin of its group in the declared
  # list. For a service declaring
  # `use MallaService, plugins: [PluginA, PluginB, PluginC]` (all in the same
  # group), PluginB depends on PluginA and PluginC on PluginB, so they start
  # PluginA -> PluginB -> PluginC and the callback execution order is:
  #   MyService -> PluginC -> PluginB -> PluginA
  # (see guides/04-plugins.md).
  # Plugins are processed in declaration order; the result keeps that order.
  defp add_group_deps(plugins), do: add_group_deps(plugins, [], %{})

  # Base case: no more plugins, return accumulated list in declaration order.
  defp add_group_deps([], acc, _groups), do: Enum.reverse(acc)

  # Convert atom plugin to tuple with empty deps.
  defp add_group_deps([plugin | rest], acc, groups) when is_atom(plugin),
    do: add_group_deps([{plugin, []} | rest], acc, groups)

  # Process each plugin tuple, checking for group membership.
  defp add_group_deps([{plugin, deps} | rest], acc, groups) do
    # Retrieve plugin options, defaulting to empty list if not available.
    opts =
      case get_plugin_opts(plugin) do
        {:ok, opts} -> opts
        _ -> []
      end

    # Check if the plugin belongs to a group.
    case Keyword.get(opts, :group) do
      nil ->
        # No group: add plugin as-is.
        add_group_deps(rest, [{plugin, deps} | acc], groups)

      group ->
        # Plugin is in a group: update groups map with this plugin as the latest in the group.
        groups2 = Map.put(groups, group, plugin)

        case Map.get(groups, group) do
          nil ->
            # First plugin in this group: just record it.
            add_group_deps(rest, [{plugin, deps} | acc], groups2)

          last_member_plugin ->
            # Subsequent plugin in group: add dependency on the previous one.
            add_group_deps(rest, [{plugin, [last_member_plugin | deps]} | acc], groups2)
        end
    end
  end

  # Recursively builds the full dependency graph for all plugins.
  # 'all' accumulates all plugins with deps, 'real' tracks non-optional, 'optional' tracks optional.
  # Base case: return accumulated lists.
  defp add_all_deps([], _service, all, real, optional), do: {all, real, optional}

  # Process each plugin tuple.
  defp add_all_deps([{plugin, deps} | rest], service, all, real, optional) do
    case Keyword.get(all, plugin) do
      nil ->
        # First encounter: get its dependencies.
        case get_plugin_deps(plugin, deps, service, real, optional) do
          :ignore ->
            # Optional and not found: skip.
            add_all_deps(rest, service, all, real, optional)

          {new_deps, real, optional} ->
            # Add new deps to the list and recurse.
            add_all_deps(new_deps ++ rest, service, [{plugin, new_deps} | all], real, optional)
        end

      prev_deps ->
        # Already seen: merge dependencies.
        deps = :lists.usort(prev_deps ++ deps)
        all = Keyword.put(all, plugin, deps)
        add_all_deps(rest, service, all, real, optional)
    end
  end

  # Convert atom plugin to tuple.
  defp add_all_deps([plugin | rest], service, all, real, optional) when is_atom(plugin),
    do: add_all_deps([{plugin, []} | rest], service, all, real, optional)

  # Error on invalid plugin name.
  defp add_all_deps([other | _], _service, _all, _real, _optional),
    do: raise("Invalid plugin name: #{other}")

  # Retrieves and processes dependencies for a specific plugin.
  # Handles the service module specially, and for others, loads and inspects plugin options.
  # Updates real and optional lists accordingly.
  defp get_plugin_deps(plugin, base_deps, service, real, optional) do
    case service do
      %{id: ^plugin, plugins: plugins} ->
        # Service module depends on BasePlugin and all declared plugins.
        get_plugin_deps_list([Malla.Plugins.Base | plugins], [], real, optional)

      _ ->
        # Ensure plugin is compiled.
        _result = Code.ensure_compiled(plugin)

        case get_plugin_opts(plugin) do
          {:ok, opts} ->
            # Get plugin's declared dependencies and process them.
            plugin_deps = Keyword.get(opts, :plugin_deps, [])
            {deps, real, optional} = get_plugin_deps_list(plugin_deps, [], real, optional)
            # Combine with base deps, add BasePlugin, remove self, and deduplicate.
            deps = :lists.usort(base_deps ++ [Malla.Plugins.Base | deps]) -- [plugin]
            {deps, real, optional}

          {:error, error} ->
            # Plugin not found: if optional, ignore; else raise error.
            case Enum.member?(optional, plugin) do
              true ->
                :ignore

              false ->
                raise "Cannot find plugin #{inspect(plugin)} for #{inspect(service.id)}: #{inspect(error)}"
            end
        end
    end
  end

  # Processes a list of plugin dependencies, updating real and optional lists.
  # Base case: return accumulated.
  defp get_plugin_deps_list([], deps, real, optional), do: {deps, real, optional}

  # Handle tuple {plugin, opts}, checking if optional.
  defp get_plugin_deps_list([{plugin, opts} | rest], deps, real, optional) when is_atom(plugin) do
    case opts[:optional] do
      true ->
        # Optional: add to deps and optional list.
        get_plugin_deps_list(rest, [plugin | deps], real, [plugin | optional])

      _ ->
        # Required: add to deps and real list.
        get_plugin_deps_list(rest, [plugin | deps], [plugin | real], optional)
    end
  end

  # Convert atom to tuple with empty opts.
  defp get_plugin_deps_list([plugin | rest], deps, real, optional) when is_atom(plugin),
    do: get_plugin_deps_list([{plugin, []} | rest], deps, real, optional)

  # Attempts to load and get options for a plugin module.
  # Checks if it's a valid module and has the required function.
  defp get_plugin_opts(plugin) do
    case Code.ensure_loaded(plugin) do
      {:module, ^plugin} -> do_get_plugin_opts(plugin)
      {:error, :embedded} -> do_get_plugin_opts(plugin)
      _ -> {:error, :not_a_module}
    end
  end

  # Retrieves plugin options by calling the plugin_use_spec function if available.
  defp do_get_plugin_opts(plugin) do
    case function_exported?(plugin, :plugin_use_spec, 0) do
      true -> {:ok, plugin.plugin_use_spec()}
      false -> {:error, :not_a_plugin}
    end
  end

  ## ===================================================================
  ## Callbacks
  ## ===================================================================

  # Takes the plugin chain  finds the callbacks that each one exports,
  # inserting it in 'callbacks' key
  # Builds the callbacks map by traversing the plugin chain in reverse order.
  # Collects callback definitions from each plugin and maps them to {name, arity} keys.
  def get_callbacks(%Service{id: srv_id, plugin_chain: plugin_chain} = service, callbacks) do
    callbacks = get_callbacks(Enum.reverse(plugin_chain), srv_id, callbacks, %{})
    %Service{service | callbacks: callbacks}
  end

  # Base case: convert accumulated map to list of {key, value} tuples.
  defp get_callbacks([], _srv_id, _callbacks, acc), do: Map.to_list(acc)

  # Handle the service module itself.
  defp get_callbacks([srv_id | rest], srv_id, callbacks, acc) do
    acc = do_add_callbacks(srv_id, true, callbacks, acc)
    get_callbacks(rest, srv_id, callbacks, acc)
  end

  # Handle a plugin: extract its callback attributes and add to accumulator.
  defp get_callbacks([plugin | rest], srv_id, callbacks0, acc) do
    attrs = plugin.module_info()[:attributes]
    callbacks = Keyword.get_values(attrs, :plugin_callbacks)
    acc = do_add_callbacks(plugin, false, callbacks, acc)
    get_callbacks(rest, srv_id, callbacks0, acc)
  end

  # Adds callbacks from a plugin to the accumulator map.
  # For each callback, determines the real function name (appending "_malla_service" for services),
  # and prepends the plugin to the list of modules implementing that callback.
  #
  # Both element shapes below are live, depending on the source of `callbacks`:
  #   * `{name, arity}`   — the service module's own callbacks, read via
  #     `Module.get_attribute(:plugin_callbacks)` at compile time (flat tuples).
  #   * `[{name, arity}]` — a plugin's callbacks, read via
  #     `plugin.module_info()[:attributes]`, where each persisted
  #     `accumulate: true` entry is wrapped in a single-element list.
  # Do NOT remove the list-wrapped clause: it is the active path for every
  # plugin's callbacks; dropping it breaks compilation of any service using a plugin.
  defp do_add_callbacks(plugin, is_service, callbacks, acc) do
    :lists.usort(callbacks)
    |> Enum.reduce(
      acc,
      fn
        {name, arity}, acc ->
          # Compute the actual function name to call.
          real_name = if is_service, do: String.to_atom("#{name}_malla_service"), else: name

          # Get existing list and prepend this plugin.
          plugins = Map.get(acc, {name, arity}, [])
          Map.put(acc, {name, arity}, [{plugin, real_name} | plugins])

        [{name, arity}], acc ->
          # List-wrapped callback (plugin path, see note above).
          real_name = if is_service, do: String.to_atom("#{name}_malla_service"), else: name
          plugins = Map.get(acc, {name, arity}, [])
          Map.put(acc, {name, arity}, [{plugin, real_name} | plugins])
      end
    )
  end
end
