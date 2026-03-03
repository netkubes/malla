defmodule Service1.Plugins.Test do
  @moduledoc """
  Comprehensive test suite for Malla's plugin system using Service1.

  This test suite validates the core mechanisms of Malla's compile-time callback
  chaining system. It covers:

  1. **Plugin Chain Compilation** - Verifies dependency resolution and ordering
  2. **Callback Registration** - Ensures callbacks are registered in correct chain order
  3. **Callback Execution** - Tests runtime behavior of callback chains
  4. **Service Lifecycle** - Validates service startup and shutdown

  ## What This Tests

  ### Plugin Dependency Resolution
  Service1 declares plugins in one order but Malla's topological sort
  reorders them based on dependencies:

  **Declared order:**
  ```
  [Plugin1_4, Plugin1_3, Plugin1_1, Plugin1_2]
  ```

  **Actual execution order (after topological sort):**
  ```
  [Service1, Plugin1_3, Plugin1_2, Plugin1_4, Plugin1_1, Malla.Plugins.Base]
  ```

  This ordering ensures dependencies are satisfied: each plugin appears AFTER
  all plugins that depend on it.

  ### Callback Chain Behavior
  Tests validate three key callback chain behaviors:

  1. **Stopping** - A plugin returns a value to halt the chain
  2. **Continuing** - A plugin returns `:cont` to pass to next plugin
  3. **Modifying** - A plugin returns `{:cont, new_args}` to transform arguments

  ### Compile-Time vs Runtime
  - **Compile-time**: Plugin chains are built when the service module is compiled
  - **Runtime**: Callbacks execute through the pre-built chain with zero overhead

  ## Test Organization

  Tests are organized into five describe blocks:

  1. **plugin chain compilation** - Validates compile-time chain building
  2. **callback execution with fun1** - Tests multi-plugin chain with arg modification
  3. **callback execution with fun2** - Tests single-plugin callback
  4. **callback execution with fun3** - Tests pass-through pattern
  5. **callback execution with fun4** - Tests multi-level interception
  6. **service lifecycle** - Tests service startup and shutdown

  ## Key Testing Patterns

  ### Pattern 1: Selective Interception
  Different plugins intercept specific patterns:
  ```elixir
  Service1.fun1(:stop_at_service, x)  # Handled by Service1
  Service1.fun1(:stop_at_3, x)        # Handled by Plugin1_3
  Service1.fun1(:stop_at_4, x)        # Handled by Plugin1_4
  Service1.fun1(x, y)                 # Reaches Plugin1_1
  ```

  ### Pattern 2: Argument Transformation
  ```elixir
  Service1.fun1(:change_at_4, "val")
  # Plugin1_4 transforms args
  # Plugin1_1 receives modified args
  # Returns: {:plugin1_1, :change_at_4, "val"}
  ```

  ### Pattern 3: Pass-Through Chain
  ```elixir
  Service1.fun3()
  # Service1.fun3 returns :cont (pass-through)
  # Plugin1_3.fun3 returns :plugin1_3 (handles)
  # Final result: :plugin1_3
  ```

  ## Related Files
  - `test/support/service1.ex` - Service and plugin implementations being tested
  """

  use ExUnit.Case, async: false

  describe "plugin chain compilation" do
    # Tests that validate compile-time plugin chain construction.
    #
    # These tests verify that Malla correctly:
    # 1. Resolves plugin dependencies via topological sort
    # 2. Registers callbacks with correct plugin chains
    # 3. Processes static configuration from use_spec

    test "plugins are ordered correctly" do
      # Retrieve the service metadata generated at compile-time
      %{plugin_chain: plugins} = Service1.service()

      # Expected order after topological sort:
      # - Service1 (top - service module always first)
      # - Plugin1_3 (depends on Plugin1_2 and Plugin1_1)
      # - Plugin1_2 (depends on Plugin1_4)
      # - Plugin1_4 (depends on Plugin1_1)
      # - Plugin1_1 (no dependencies, appears after all dependents)
      # - Malla.Plugins.Base (bottom - base plugin always last)
      assert [
               Service1,
               Service1.Plugin1_3,
               Service1.Plugin1_2,
               Service1.Plugin1_4,
               Service1.Plugin1_1,
               Malla.Plugins.Base
             ] == plugins
    end

    test "callbacks are registered with correct plugin chains" do
      # Retrieve callback registry from service metadata
      %{callbacks: callbacks} = Service1.service()

      # Convert callbacks to a simpler format for testing (just module names)
      # Original format: {{name, arity} => [{module, function}, ...]}
      # Simplified format: {{name, arity} => [module, ...]}
      simplified_callbacks =
        callbacks
        |> Enum.map(fn {{name, arity}, module_funs} ->
          {{name, arity}, Enum.map(module_funs, fn {mod, _fun} -> mod end)}
        end)
        |> Map.new()

      # Test fun1/2 callback chain
      # Only plugins that implement fun1 appear in the chain:
      # - Service1: Intercepts :stop_at_service
      # - Plugin1_3: Intercepts :stop_at_3
      # - Plugin1_4: Intercepts :stop_at_4 and :change_at_4
      # - Plugin1_1: Base implementation
      # Plugin1_2 does NOT implement fun1, so it's excluded
      assert [Service1, Service1.Plugin1_3, Service1.Plugin1_4, Service1.Plugin1_1] ==
               simplified_callbacks[{:fun1, 2}]

      # Test fun2/0 callback chain
      # Only Plugin1_2 implements fun2
      # This demonstrates single-implementation callbacks (no chain)
      assert [Service1.Plugin1_2] == simplified_callbacks[{:fun2, 0}]

      # Test fun3/0 callback chain
      # - Service1: Returns :cont (pass-through)
      # - Plugin1_3: Provides base implementation
      assert [Service1, Service1.Plugin1_3] == simplified_callbacks[{:fun3, 0}]

      # Test fun4/1 callback chain
      # - Service1: Intercepts :stop_at_service
      # - Plugin1_3: Intercepts :stop_at_3
      # - Plugin1_2: Intercepts :stop_at_2
      # - Plugin1_4: Base implementation
      assert [Service1, Service1.Plugin1_3, Service1.Plugin1_2, Service1.Plugin1_4] ==
               simplified_callbacks[{:fun4, 1}]

      # Verify base plugin callbacks exist
      # These are provided by Malla.Plugins.Base
      assert Map.has_key?(simplified_callbacks, {:malla_authorize, 3})
      assert Map.has_key?(simplified_callbacks, {:service_cb_in, 3})
    end

    test "config is processed correctly through plugin chain" do
      # Retrieve static config from use_spec
      %{config: config} = Service1.service()

      # Static config from use_spec (not yet processed through plugin_config/3)
      # At compile time, this is just the config passed to use Malla.Service
      # At runtime, plugin_config/3 callbacks modify this during initialization
      assert [key1: :val1, key2: :val2] == config
    end
  end

  describe "callback execution with fun1" do
    # Tests fun1/2 callback execution through multi-plugin chain.
    #
    # fun1 is implemented in four plugins:
    # - Service1: Intercepts :stop_at_service
    # - Plugin1_3: Intercepts :stop_at_3
    # - Plugin1_4: Intercepts :stop_at_4 and :change_at_4
    # - Plugin1_1: Base implementation
    #
    # Execution flow:
    # Service1 → Plugin1_3 → Plugin1_4 → Plugin1_1

    test "stops at service level when requested" do
      # Pattern: :stop_at_service
      # Service1.fun1(:stop_at_service, b) returns {:service, b}
      # Chain stops immediately at service level
      assert Service1.fun1(:stop_at_service, 0) == {:service, 0}

      # Pattern: :stop_at_3
      # Service1 returns :cont
      # Plugin1_3.fun1(:stop_at_3, b) returns {:plugin1_3, b}
      # Chain stops at Plugin1_3
      assert Service1.fun1(:stop_at_3, 3) == {:plugin1_3, 3}

      # Pattern: :stop_at_4
      # Service1 returns :cont
      # Plugin1_3 returns :cont
      # Plugin1_4.fun1(:stop_at_4, b) returns {:plugin1_4, b}
      # Chain stops at Plugin1_4
      assert Service1.fun1(:stop_at_4, "c") == {:plugin1_4, "c"}

      # Pattern: :change_at_4
      # Service1 returns :cont
      # Plugin1_3 returns :cont
      # Plugin1_4.fun1(:change_at_4, b) returns {:cont, [:change_at_4, b]}
      # Plugin1_1.fun1(:change_at_4, "d") returns {:plugin1_1, :change_at_4, "d"}
      # Demonstrates argument transformation
      assert Service1.fun1(:change_at_4, "d") == {:plugin1_1, :change_at_4, "d"}

      # Pattern: unmatched
      # Service1 returns :cont
      # Plugin1_3 returns :cont
      # Plugin1_4 returns :cont
      # Plugin1_1.fun1(1, 2) returns {:plugin1_1, 1, 2}
      # Chain reaches bottom implementation
      assert Service1.fun1(1, 2) == {:plugin1_1, 1, 2}
    end
  end

  describe "callback execution with fun2" do
    # Tests fun2/0 callback execution with single implementation.
    #
    # fun2 is ONLY implemented in Plugin1_2, demonstrating that callbacks
    # don't need to form chains. This is a simple, direct invocation.

    test "plugin1_2 callback executes correctly" do
      # fun2 only exists in Plugin1_2
      # No chain, just direct execution
      # Plugin1_2.fun2() returns :plugin1_2
      assert Service1.fun2() == :plugin1_2
    end
  end

  describe "callback execution with fun3" do
    # Tests fun3/0 callback execution with pass-through pattern.
    #
    # fun3 is implemented in:
    # - Service1: Returns :cont (intentional pass-through)
    # - Plugin1_3: Returns :plugin1_3 (actual handler)
    #
    # This demonstrates a pattern where the service participates in the
    # chain but delegates handling to a plugin.

    test "plugin1_3 callback executes correctly" do
      # Service1.fun3() returns :cont
      # Plugin1_3.fun3() returns :plugin1_3
      # Final result: :plugin1_3
      #
      # This pattern is useful when:
      # - Service wants to validate/log but not handle
      # - Plugin provides default implementation
      # - Service can override in specific cases
      assert Service1.fun3() == :plugin1_3
    end
  end

  describe "callback execution with fun4" do
    # Tests fun4/1 callback execution with multi-level interception.
    #
    # fun4 is implemented in four plugins:
    # - Service1: Intercepts :stop_at_service
    # - Plugin1_3: Intercepts :stop_at_3
    # - Plugin1_2: Intercepts :stop_at_2
    # - Plugin1_4: Base implementation
    #
    # Execution flow:
    # Service1 → Plugin1_3 → Plugin1_2 → Plugin1_4

    test "stops at service level when requested" do
      # Pattern: :stop_at_service
      # Service1.fun4(:stop_at_service) returns :service
      # Chain stops at service level
      assert Service1.fun4(:stop_at_service) == :service

      # Pattern: :stop_at_3
      # Service1 returns :cont
      # Plugin1_3.fun4(:stop_at_3) returns :plugin1_3
      # Chain stops at Plugin1_3
      assert Service1.fun4(:stop_at_3) == :plugin1_3

      # Pattern: :stop_at_2
      # Service1 returns :cont
      # Plugin1_3 returns :cont
      # Plugin1_2.fun4(:stop_at_2) returns :plugin1_2
      # Chain stops at Plugin1_2
      assert Service1.fun4(:stop_at_2) == :plugin1_2

      # Pattern: unmatched (numeric value)
      # Service1 returns :cont
      # Plugin1_3 returns :cont
      # Plugin1_2 returns :cont
      # Plugin1_4.fun4(1) returns {:plugin1_4, 1}
      # Chain reaches Plugin1_4 base implementation
      assert Service1.fun4(1) == {:plugin1_4, 1}
    end
  end

  describe "service lifecycle" do
    # Tests service startup and shutdown behavior.
    #
    # Validates that:
    # 1. Service starts successfully and registers with a name
    # 2. Service can be stopped cleanly
    # 3. Cleanup happens properly (via setup/on_exit)
    #
    # This test is marked `async: false` because it uses a named process
    # (Service1) that could conflict with parallel test execution.

    setup do
      # Cleanup function runs after each test
      on_exit(fn ->
        # If the service is still running, stop it
        if Process.whereis(Service1) do
          try do
            Service1.stop()
            # Give it time to shut down cleanly
            Process.sleep(50)
          catch
            # Service may have already exited
            :exit, _ -> :ok
          end
        end
      end)
    end

    test "service starts successfully" do
      # Start the service
      # This will:
      # 1. Call plugin_config/3 callbacks (top to bottom)
      # 2. Call plugin_start/3 callbacks (bottom to top)
      # 3. Start any supervised children
      # 4. Register the process as Service1
      {:ok, pid} = Service1.start_link()

      # Verify the process was created
      assert is_pid(pid)

      # Verify it's registered with the expected name
      assert Process.whereis(Service1) == pid
    end
  end
end
