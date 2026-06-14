defmodule RequestTestService do
  @moduledoc false
  # Test service wired with the request stack (Request -> Tracer + Status),
  # used to exercise Malla.Request.request/4 and request!/4, including the
  # behaviour when the target service is not available.

  use Malla.Service,
    class: :test,
    global: true,
    plugins: [Malla.Plugins.Request]

  # Request handler returning data as a map, per the documented contract.
  def regular_function(a, b), do: {:ok, %{sum: a + b}}
end
