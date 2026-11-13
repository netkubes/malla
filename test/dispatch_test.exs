defmodule DispatchTest.PluginB do
  @moduledoc false
  use Malla.Plugin

  defcb dt_echo(value), do: {:plugin_b, value}
end

defmodule DispatchTest.PluginA do
  @moduledoc false
  use Malla.Plugin, plugin_deps: [DispatchTest.PluginB]

  defcb dt_echo(_value), do: :cont
end

defmodule DispatchTest.Service do
  @moduledoc false
  use Malla.Service, plugins: [DispatchTest.PluginA]

  # `{:cont, value}` with a value that is not a list: the next module gets `value`
  defcb dt_echo(:replace_with_atom), do: {:cont, :replaced}
  # `{:cont, list}`: the list is the new argument list
  defcb dt_echo(:replace_with_args), do: {:cont, [:from_list]}
  defcb dt_echo(_value), do: :cont

  defcb dt_raise(), do: raise("boom")
end

defmodule DispatchTest do
  use ExUnit.Case, async: false

  alias DispatchTest.Service

  describe "continuation with new arguments" do
    test "a non-list value becomes the single argument of the next module" do
      assert Service.dt_echo(:replace_with_atom) == {:plugin_b, :replaced}
    end

    test "a list is taken as the new argument list" do
      assert Service.dt_echo(:replace_with_args) == {:plugin_b, :from_list}
    end

    test "plain :cont passes the original arguments" do
      assert Service.dt_echo(:other) == {:plugin_b, :other}
    end
  end

  describe "service id around a callback" do
    test "the caller's service id is restored when the callback raises" do
      Malla.put_service_id(:calling_service)

      try do
        assert_raise RuntimeError, "boom", fn -> Service.dt_raise() end
        assert Malla.get_service_id() == :calling_service
      after
        Malla.put_service_id(nil)
      end
    end
  end
end
