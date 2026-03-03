# Service1 and its plugins demonstrate the Malla plugin system's callback chaining mechanism.
#
# This file contains a complete example of how Malla's compile-time callback chaining works:
# - Plugin dependency ordering through topological sort
# - Callback interception and modification across plugin layers
# - Runtime configuration processing through plugin chain
# - Different patterns for stopping or continuing callback chains
#
# Architecture Overview
#
# The plugin dependency graph forms this structure:
#
# ```
# Service1 (top)
#     ├── Plugin1_3
#     │   ├── Plugin1_2
#     │   │   └── Plugin1_4
#     │   │       └── Plugin1_1 (bottom)
#     │   └── Plugin1 (shared dependency)
#     └── (other plugins as declared)
# ```
#
# After topological sort, the callback chain order is:
# `[Service1, Plugin1_3, Plugin1_2, Plugin1_4, Plugin1_1, Malla.Plugins.Base]`
#
# Callback Execution Flow
#
# When a callback is invoked (e.g., `Service1.fun1(arg1, arg2)`), execution flows
# from top to bottom through the chain:
#
# 1. **Service1** - Service-level implementation (highest priority)
# 2. **Plugin1_3** - Can intercept before Plugin1_2
# 3. **Plugin1_2** - Can intercept before Plugin1_4
# 4. **Plugin1_4** - Can intercept before Plugin1_1
# 5. **Plugin1_1** - Base implementation (lowest priority, typically executes if no one stops)
#
# Each plugin can:
# - Return a value to STOP the chain and return that value
# - Return `:cont` to CONTINUE with the same arguments
# - Return `{:cont, new_args}` or `{:cont, [arg1, arg2]}` to CONTINUE with modified arguments
#

defmodule Service1.Plugin1_1 do
  @moduledoc false
  # Plugin1_1 - Base plugin providing foundational callback implementations.
  # This is the bottom-most plugin in the dependency chain, meaning its callbacks
  # typically execute last (if no higher plugin stops the chain).

  use Malla.Plugin

  # Lifecycle callback invoked during service configuration phase.
  # This is called BEFORE the service starts, allowing plugins to validate
  # or modify the configuration. Not part of the callback chain system.
  def plugin_config(Service1, config),
    do: {:ok, Keyword.merge(config, key2: :plugin1_1, plugin1_1: :ok)}

  # Base implementation of `fun1/2` callback.
  defcb fun1(a, b), do: {:plugin1_1, a, b}
end

defmodule Service1.Plugin1_4 do
  # Plugin1_4 - Demonstrates argument interception and modification patterns.
  # Depends on Plugin1_1, placing it higher in the callback chain.
  use Malla.Plugin, plugin_deps: [Service1.Plugin1_1]

  defcb fun4(a), do: {:plugin1_4, a}

  defcb fun1(:stop_at_4, b), do: {:plugin1_4, b}
  defcb fun1(:change_at_4, b), do: {:cont, [:change_at_4, b]}
  defcb fun1(_, _), do: :cont
end

defmodule Service1.Plugin1_2 do
  # Plugin1_2 - Demonstrates single-implementation callbacks and selective interception.
  # Depends on Plugin1_4, placing it higher in the chain than Plugin1_4 and Plugin1_1.

  use Malla.Plugin, plugin_deps: [Service1.Plugin1_4]

  defcb fun4(:stop_at_2), do: :plugin1_2

  defcb fun4(_), do: :cont

  defcb fun2, do: :plugin1_2
end

defmodule Service1.Plugin1_3 do
  # Plugin1_3 - Demonstrates multiple dependencies and high-priority interception.
  # Depends on both Plugin1_2 and Plugin1_1, creating a diamond dependency:
  #
  # Plugin1_3
  #   ├── Plugin1_2 → Plugin1_4 → Plugin1_1
  #   └── Plugin1_1 (direct)
  #
  use Malla.Plugin, plugin_deps: [Service1.Plugin1_2, Service1.Plugin1_1]

  @impl true
  def plugin_config(Service1, config),
    do: {:ok, Keyword.merge(config, key2: :plugin1_2, plugin1_2: :ok)}

  defcb fun1(:stop_at_3, b), do: {:plugin1_3, b}

  defcb fun1(_, _), do: :cont

  defcb fun4(:stop_at_3), do: :plugin1_3

  defcb fun4(_), do: :cont

  defcb fun3, do: :plugin1_3
end

defmodule Service1 do
  # Service1 - Main service demonstrating Malla's plugin system.
  # This service uses four plugins to demonstrate callback chaining, plugin
  # dependency resolution, and configuration management:
  # [Plugin1_4, Plugin1_3, Plugin1_1, Plugin1_2]
  # ```
  # Actual execution order** (after dependency resolution):
  # [Service1, Plugin1_3, Plugin1_2, Plugin1_4, Plugin1_1, Malla.Plugins.Base]
  #
  # The execution order is determined by topological sort of the dependency graph,
  # NOT by the declaration order. Dependencies are resolved to ensure that:
  # - A plugin always executes BEFORE its dependencies
  # - The service module is always first
  # - Malla.Plugins.Base is always last

  use Malla.Service,
    plugins: [
      Service1.Plugin1_4,
      Service1.Plugin1_3,
      Service1.Plugin1_1,
      Service1.Plugin1_2
    ],
    class: :test_service,
    key1: :val1,
    key2: :val2

  defcb fun1(:stop_at_service, b), do: {:service, b}
  defcb fun1(_, _), do: :cont

  defcb fun4(:stop_at_service), do: :service
  defcb fun4(_), do: :cont

  defcb fun3, do: :cont
end
