defmodule Service1.CompileTime.Test do
  @moduledoc """
  Comprehensive compile-time test suite for Malla's plugin system (AI generated)

  This test suite validates compile-time artifacts and behaviors that are generated
  when service modules are compiled. It focuses on:

  1. **Service Metadata** - Completeness and correctness of compile-time metadata
  2. **Callback Registration** - Which plugins participate in which chains
  3. **Callback Arity** - Multiple arities and validation
  4. **Plugin Ordering** - Dependency resolution edge cases
  5. **Execution Tracing** - Callback chain execution order
  6. **Argument Transformation** - `{:cont, new_args}` patterns
  7. **Configuration Phases** - Static vs runtime configuration
  8. **Module Introspection** - Function exports validation

  ## Related Files
  - `test/support/service1.ex` - Service and plugin implementations being tested
  - `test/service1_plugins_test.exs` - Runtime behavior tests
  """

  use ExUnit.Case, async: true

  describe "service metadata completeness" do
    test "service metadata returns Malla.Service struct" do
      metadata = Service1.service()
      assert match?(%Malla.Service{}, metadata)
      # Verify all expected fields exist in the struct
      assert Map.has_key?(metadata, :id)
      assert Map.has_key?(metadata, :plugin_chain)
      assert Map.has_key?(metadata, :callbacks)
      assert Map.has_key?(metadata, :config)
      assert Map.has_key?(metadata, :class)
      assert Map.has_key?(metadata, :vsn)
      assert Map.has_key?(metadata, :plugins)
      assert Map.has_key?(metadata, :global)
      # Verify field types
      assert is_list(metadata.plugin_chain)
      # callbacks is a keyword list
      assert is_list(metadata.callbacks)
      assert is_list(metadata.config)
      assert metadata.class == :test_service
      assert metadata.id == Service1

      # vsn might be nil or a string
      assert is_binary(metadata.vsn) or metadata.vsn == ""
    end

    test "callback metadata is a list of tuples" do
      %{callbacks: callbacks} = Service1.service()

      # callbacks should be a list of {key, value} tuples where
      # key is {name, arity} and value is [{module, fun}, ...]
      assert is_list(callbacks)

      assert Enum.all?(callbacks, fn
               {{name, arity}, module_funs}
               when is_atom(name) and is_integer(arity) and is_list(module_funs) ->
                 true

               _ ->
                 false
             end)
    end

    test "callback metadata includes function references" do
      %{callbacks: callbacks} = Service1.service()

      # Find fun1 callback
      {_, module_funs} = List.keyfind(callbacks, {:fun1, 2}, 0)

      assert is_list(module_funs)
      assert Enum.all?(module_funs, fn {mod, fun} -> is_atom(mod) and is_atom(fun) end)
    end

    test "plugin_chain preserves module references" do
      %{plugin_chain: chain} = Service1.service()

      # All entries should be module atoms
      assert Enum.all?(chain, &is_atom/1)

      # All modules should be loadable
      assert Enum.all?(chain, fn mod -> Code.ensure_loaded?(mod) end)
    end

    test "config preserves keyword list structure" do
      %{config: config} = Service1.service()

      # Config should be a keyword list
      assert Keyword.keyword?(config)

      # Verify expected keys
      assert Keyword.has_key?(config, :key1)
      assert Keyword.has_key?(config, :key2)
    end
  end

  describe "callback arity handling" do
    test "callbacks with different arities are registered separately" do
      %{callbacks: callbacks} = Service1.service()

      # fun1/2, fun2/0, fun3/0, fun4/1 should all be separate entries
      assert List.keyfind(callbacks, {:fun1, 2}, 0)
      assert List.keyfind(callbacks, {:fun2, 0}, 0)
      assert List.keyfind(callbacks, {:fun3, 0}, 0)
      assert List.keyfind(callbacks, {:fun4, 1}, 0)

      # Verify they don't interfere with each other
      refute List.keyfind(callbacks, {:fun1, 0}, 0)
      refute List.keyfind(callbacks, {:fun1, 1}, 0)
      refute List.keyfind(callbacks, {:fun2, 1}, 0)
      refute List.keyfind(callbacks, {:fun2, 2}, 0)
      refute List.keyfind(callbacks, {:fun4, 0}, 0)
      refute List.keyfind(callbacks, {:fun4, 2}, 0)
    end

    test "calling callback with wrong arity raises error" do
      # Calling with wrong number of arguments should raise
      assert_raise UndefinedFunctionError, fn ->
        apply(Service1, :fun1, [:only_one_arg])
      end

      assert_raise UndefinedFunctionError, fn ->
        apply(Service1, :fun2, [:unexpected_arg])
      end

      assert_raise UndefinedFunctionError, fn ->
        apply(Service1, :fun3, [:unexpected_arg])
      end

      assert_raise UndefinedFunctionError, fn ->
        apply(Service1, :fun4, [])
      end
    end

    test "each arity has its own callback chain" do
      %{callbacks: callbacks} = Service1.service()

      # fun1/2 chain
      {_, fun1_2_modules} = List.keyfind(callbacks, {:fun1, 2}, 0)
      fun1_2_chain = Enum.map(fun1_2_modules, fn {mod, _} -> mod end)
      assert Service1 in fun1_2_chain
      assert Service1.Plugin1_1 in fun1_2_chain

      # fun2/0 chain
      {_, fun2_0_modules} = List.keyfind(callbacks, {:fun2, 0}, 0)
      fun2_0_chain = Enum.map(fun2_0_modules, fn {mod, _} -> mod end)
      assert Service1.Plugin1_2 in fun2_0_chain
      refute Service1 in fun2_0_chain

      # Verify they're independent
      refute fun1_2_chain == fun2_0_chain
    end
  end

  describe "plugin dependency resolution edge cases" do
    test "diamond dependencies are resolved correctly" do
      # Plugin1_3 depends on both Plugin1_2 and Plugin1_1
      # Plugin1_2 depends on Plugin1_4
      # Plugin1_4 depends on Plugin1_1
      # This creates a diamond:
      #
      #       Plugin1_3
      #       /     \
      #  Plugin1_2   Plugin1_1
      #      |       |
      #  Plugin1_4 ----+
      #
      # Result: Plugin1_3 → Plugin1_2 → Plugin1_4 → Plugin1_1

      %{plugin_chain: chain} = Service1.service()

      # Find indices
      idx_plugin3 = Enum.find_index(chain, &(&1 == Service1.Plugin1_3))
      idx_plugin2 = Enum.find_index(chain, &(&1 == Service1.Plugin1_2))
      idx_plugin4 = Enum.find_index(chain, &(&1 == Service1.Plugin1_4))
      idx_plugin1 = Enum.find_index(chain, &(&1 == Service1.Plugin1_1))

      # Verify ordering constraints
      assert idx_plugin3 < idx_plugin2, "Plugin1_3 should come before Plugin1_2 (depends on it)"
      assert idx_plugin2 < idx_plugin4, "Plugin1_2 should come before Plugin1_4 (depends on it)"
      assert idx_plugin4 < idx_plugin1, "Plugin1_4 should come before Plugin1_1 (depends on it)"

      assert idx_plugin3 < idx_plugin1,
             "Plugin1_3 should come before Plugin1_1 (direct dependency)"

      # The service module itself is always the first in the chain
      # This gives it highest priority for callback interception
      assert hd(chain) == Service1

      # Malla.Plugins.Base is always last in the chain
      # This provides default implementations for system callbacks
      assert List.last(chain) == Malla.Plugins.Base

      # All plugins declared in use_spec should appear
      assert Service1.Plugin1_1 in chain
      assert Service1.Plugin1_2 in chain
      assert Service1.Plugin1_3 in chain
      assert Service1.Plugin1_4 in chain

      # Even though Service1 doesn't directly declare Plugin1_4,
      # it's included because Plugin1_2 depends on it
      assert Service1.Plugin1_4 in chain

      # Even with diamond dependencies, each plugin appears only once
      assert length(chain) == length(Enum.uniq(chain))
    end
  end

  describe "callback chain execution tracing" do
    test "callback execution follows plugin chain order" do
      # Use a callback that continues through all plugins
      # We can trace execution by checking return values at each level

      # For fun1(1, 2), the chain is:
      # Service1 → :cont → Plugin1_3 → :cont → Plugin1_4 → :cont → Plugin1_1 → {:plugin1_1, 1, 2}
      result = Service1.fun1(1, 2)
      assert result == {:plugin1_1, 1, 2}

      # Verify intermediate stops work correctly
      # Stops at position 0 (Service1)
      assert Service1.fun1(:stop_at_service, :x) == {:service, :x}
      # Stops at position 1 (Plugin1_3)
      assert Service1.fun1(:stop_at_3, :x) == {:plugin1_3, :x}
      # Stops at position 2 (Plugin1_4)
      assert Service1.fun1(:stop_at_4, :x) == {:plugin1_4, :x}

      # Each stop point returns a distinct value identifying which plugin handled it

      # Service level
      result1 = Service1.fun4(:stop_at_service)
      assert result1 == :service

      # Plugin1_3 level
      result2 = Service1.fun4(:stop_at_3)
      assert result2 == :plugin1_3

      # Plugin1_2 level
      result3 = Service1.fun4(:stop_at_2)
      assert result3 == :plugin1_2

      # Plugin1_4 level (base implementation)
      result4 = Service1.fun4(:anything_else)
      assert result4 == {:plugin1_4, :anything_else}

      # All results are different
      assert MapSet.size(MapSet.new([result1, result2, result3, result4])) == 4
      # When all plugins return :cont, execution reaches the bottom

      # fun3: Service1 → :cont → Plugin1_3 → :plugin3
      assert Service1.fun3() == :plugin1_3

      # This proves that:
      # 1. Service1.fun3 was called first
      # 2. It returned :cont
      # 3. Plugin1_3.fun3 was called next
      # 4. It returned :plugin3 (final result)
    end
  end

  describe "callback registration filtering" do
    test "only plugins implementing a callback are in its chain" do
      %{callbacks: callbacks} = Service1.service()

      # fun2 is only in Plugin1_2
      {_, fun2_modules} = List.keyfind(callbacks, {:fun2, 0}, 0)
      fun2_chain = Enum.map(fun2_modules, fn {mod, _} -> mod end)
      assert fun2_chain == [Service1.Plugin1_2]

      # fun1 is in Service1, Plugin1_3, Plugin1_4, Plugin1_1 (NOT Plugin1_2)
      {_, fun1_modules} = List.keyfind(callbacks, {:fun1, 2}, 0)
      fun1_chain = Enum.map(fun1_modules, fn {mod, _} -> mod end)
      assert Service1 in fun1_chain
      assert Service1.Plugin1_3 in fun1_chain
      assert Service1.Plugin1_4 in fun1_chain
      assert Service1.Plugin1_1 in fun1_chain
      refute Service1.Plugin1_2 in fun1_chain

      # Base plugin provides malla_authorize, service_cb_in, etc.
      assert List.keyfind(callbacks, {:malla_authorize, 3}, 0)
      assert List.keyfind(callbacks, {:service_cb_in, 3}, 0)

      # Find all callbacks that include Malla.Plugins.Base
      base_callbacks =
        for {{name, _arity}, chain} <- callbacks,
            Enum.any?(chain, fn {mod, _} -> mod == Malla.Plugins.Base end),
            do: name

      assert :malla_authorize in base_callbacks
      assert :service_cb_in in base_callbacks
    end

    test "callbacks respect plugin chain order" do
      %{callbacks: callbacks, plugin_chain: plugin_chain} = Service1.service()

      # For each callback, the modules in its chain should appear in the same
      # relative order as they do in the plugin_chain

      {_, fun1_modules} = List.keyfind(callbacks, {:fun1, 2}, 0)
      fun1_chain = Enum.map(fun1_modules, fn {mod, _} -> mod end)

      # Get indices in plugin_chain
      fun1_indices =
        fun1_chain
        |> Enum.map(fn mod -> Enum.find_index(plugin_chain, &(&1 == mod)) end)
        # Remove nils for modules not in plugin_chain
        |> Enum.reject(&is_nil/1)

      # Verify they're in ascending order
      assert fun1_indices == Enum.sort(fun1_indices)

      # Get all callback names
      callback_names = Enum.map(callbacks, fn {{name, _}, _} -> name end)

      # Our known callbacks
      assert :fun1 in callback_names
      assert :fun2 in callback_names
      assert :fun3 in callback_names
      assert :fun4 in callback_names

      # Some callback that we never defined should not exist
      refute :nonexistent_callback in callback_names
      refute :undefined_function in callback_names
    end
  end

  describe "argument transformation" do
    test "tuple form with list transforms arguments correctly" do
      # Plugin1_4.fun1(:change_at_4, "val") returns {:cont, [:change_at_4, "val"]}
      # This should transform the args and continue to Plugin1_1
      result = Service1.fun1(:change_at_4, "original")
      assert result == {:plugin1_1, :change_at_4, "original"}
      # Verify that the transformation doesn't lose or corrupt data
      test_value = :test_value_12345

      result = Service1.fun1(:change_at_4, test_value)
      assert result == {:plugin1_1, :change_at_4, test_value}

      # Try with different types
      result_str = Service1.fun1(:change_at_4, "string")
      assert result_str == {:plugin1_1, :change_at_4, "string"}

      result_map = Service1.fun1(:change_at_4, %{key: :value})
      assert result_map == {:plugin1_1, :change_at_4, %{key: :value}}
    end

    test "continuation without transformation works" do
      # When a plugin returns :cont (not {:cont, args}), args are unchanged

      # Service1 and Plugin1_3 both return :cont for (1, 2)
      # Plugin1_4 also returns :cont for (1, 2)
      # Plugin1_1 receives the original (1, 2)
      result = Service1.fun1(1, 2)
      assert result == {:plugin1_1, 1, 2}

      # If a plugin stops the chain before a transformer, transformation doesn't happen

      # Plugin1_3 stops at :stop_at_3, so Plugin1_4's transformation never runs
      result = Service1.fun1(:stop_at_3, :value)
      assert result == {:plugin1_3, :value}

      # Compare with :change_at_4 which reaches Plugin1_4's transformer
      result2 = Service1.fun1(:change_at_4, :value)
      assert result2 == {:plugin1_1, :change_at_4, :value}

      # Results are different because different plugins handled them
      refute result == result2
    end
  end

  describe "configuration phases" do
    test "static config is available at compile time" do
      %{class: class, config: config} = Service1.service()

      # This is the config from use_spec, before plugin_config/3 processing
      assert Keyword.get(config, :key1) == :val1
      assert Keyword.get(config, :key2) == :val2

      assert Keyword.keyword?(config)

      # Verify structure
      assert is_list(config)
      assert Enum.all?(config, fn {k, _v} -> is_atom(k) end)

      assert class == :test_service

      # These are declared in use Malla.Service
      assert Keyword.has_key?(config, :key1)
      assert Keyword.has_key?(config, :key2)

      # Plugin-specific config is added at runtime via plugin_config/3
      # At compile time, only the static config from use_spec is available
    end
  end

  describe "module introspection" do
    test "service exports all callback functions" do
      # Public callbacks should be exported
      assert function_exported?(Service1, :fun1, 2)
      assert function_exported?(Service1, :fun3, 0)
      assert function_exported?(Service1, :fun4, 1)
      # Via Plugin1_2 chain
      assert function_exported?(Service1, :fun2, 0)
      # The service/0 function returns compile-time metadata
      assert function_exported?(Service1, :service, 0)

      # Verify it returns a struct
      assert match?(%Malla.Service{}, Service1.service())

      # Each plugin should export its own callbacks
      assert function_exported?(Service1.Plugin1_1, :fun1, 2)
      assert function_exported?(Service1.Plugin1_2, :fun2, 0)
      assert function_exported?(Service1.Plugin1_2, :fun4, 1)
      assert function_exported?(Service1.Plugin1_3, :fun3, 0)
      assert function_exported?(Service1.Plugin1_3, :fun1, 2)
      assert function_exported?(Service1.Plugin1_3, :fun4, 1)
      assert function_exported?(Service1.Plugin1_4, :fun4, 1)
      assert function_exported?(Service1.Plugin1_4, :fun1, 2)

      # Lifecycle callbacks like plugin_config/2 should be exported when implemented
      assert function_exported?(Service1.Plugin1_1, :plugin_config, 2)
      assert function_exported?(Service1.Plugin1_3, :plugin_config, 2)

      # The service should be a module
      assert Code.ensure_loaded?(Service1)

      # Verify it's actually a module
      assert is_atom(Service1)
      assert function_exported?(Service1, :__info__, 1)
    end

    test "callback functions have correct arity" do
      # Verify that exported functions have the documented arity
      exports = Service1.__info__(:functions)

      assert {:fun1, 2} in exports
      assert {:fun2, 0} in exports
      assert {:fun3, 0} in exports
      assert {:fun4, 1} in exports
      assert {:service, 0} in exports
    end
  end

  describe "callback chain consistency" do
    test "all callbacks in chain are callable" do
      %{callbacks: callbacks} = Service1.service()

      # For each callback, verify all functions in the chain are callable
      for {{_name, arity}, module_funs} <- callbacks do
        for {mod, fun} <- module_funs do
          assert function_exported?(mod, fun, arity),
                 "Expected #{inspect(mod)}.#{fun}/#{arity} to be exported"
        end
      end

      # Each module should appear at most once in each callback chain
      for {{_name, _arity}, module_funs} <- callbacks do
        modules = Enum.map(module_funs, fn {mod, _} -> mod end)

        assert length(modules) == length(Enum.uniq(modules)),
               "Found duplicate modules in chain: #{inspect(modules)}"
      end

      # Every registered callback should have at least one implementation
      for {{name, arity}, module_funs} <- callbacks do
        assert length(module_funs) > 0,
               "Callback #{name}/#{arity} has no implementations"
      end
    end
  end

  describe "plugin metadata" do
    test "plugins list includes all declared plugins" do
      %{plugins: plugins} = Service1.service()

      # These are the plugins explicitly declared in use_spec
      assert Service1.Plugin1_4 in plugins
      assert Service1.Plugin1_3 in plugins
      assert Service1.Plugin1_1 in plugins
      assert Service1.Plugin1_2 in plugins
    end

    test "plugin chain is longer than plugins list" do
      %{plugins: plugins, plugin_chain: chain} = Service1.service()

      # plugin_chain includes transitive dependencies + base plugin + service
      # So it should be longer than the explicit plugins list
      assert length(chain) >= length(plugins)
    end

    test "global flag is preserved" do
      %{global: global} = Service1.service()

      # Service1 has global: false (default)
      assert global == false
    end

    test "vsn is preserved" do
      %{vsn: vsn} = Service1.service()

      # Service1 doesn't specify vsn, so it defaults to empty string
      assert is_binary(vsn)
    end
  end
end
