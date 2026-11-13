defmodule NodeLegacyReplyTest do
  use ExUnit.Case, async: true

  # A remote node on an older Malla answers `:service_not_available` without the
  # prefix: Malla.Node.call/4 must take it as "not available here" and move on.
  defmodule OldNode do
    def reply(), do: {:error, :service_not_available}
  end

  test "an unprefixed not-available reply is read as the prefixed one" do
    assert Malla.Node.call(OldNode, :reply, [], nodes: [node()]) ==
             {:error, :malla_service_not_available}
  end
end
