defmodule Malla.PluginOrderTest do
  @moduledoc false
  # Order of the plugin chain for plugins that do not depend on each other: the
  # one declared first in `plugins:` is called first, each plugin's
  # `plugin_deps` go right below it, and a shared dependency goes below every
  # plugin that needs it. The order must not depend on the Elixir/OTP version.

  use ExUnit.Case, async: true

  alias Malla.Plugins.Base

  defmodule X do
    use Malla.Plugin
  end

  defmodule A do
    use Malla.Plugin, plugin_deps: [X]
  end

  defmodule B do
    use Malla.Plugin
  end

  defmodule C do
    use Malla.Plugin, plugin_deps: [X]
  end

  defmodule AB do
    use Malla.Service, plugins: [A, B]
  end

  defmodule BA do
    use Malla.Service, plugins: [B, A]
  end

  defmodule ABC do
    use Malla.Service, plugins: [A, B, C]
  end

  test "independent plugins keep the order of plugins:, dependencies go right below" do
    assert AB.service().plugin_chain == [AB, A, X, B, Base]
    assert BA.service().plugin_chain == [BA, B, A, X, Base]
  end

  test "a shared dependency goes below every plugin that needs it" do
    assert ABC.service().plugin_chain == [ABC, A, B, C, X, Base]
  end
end
