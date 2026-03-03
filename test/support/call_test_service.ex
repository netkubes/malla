defmodule CallTestService do
  @moduledoc false
  # Test service for testing Malla.local, Malla.remote, and Malla.call functions.
  #
  # This service provides various functions and callbacks to test:
  # - Local callback invocation
  # - Remote callback invocation
  # - Exception handling
  # - Service availability checking

  use Malla.Service,
    class: :test,
    global: true

  # Regular function (not a callback)
  def regular_function(a, b), do: {:ok, a + b}

  # Callback function
  defcb callback_function(a, b), do: {:callback_result, a * b}

  # Function that returns the current service_id
  def get_current_service_id(), do: Malla.get_service_id()

  # Function that raises an exception
  def raise_error(message), do: raise(RuntimeError, message: message)

  # Callback that raises an exception
  defcb callback_raise_error(message), do: raise(RuntimeError, message: message)

  # Function that returns a tuple with complex data
  def complex_return(data), do: {:ok, %{input: data, timestamp: System.system_time()}}

  # Callback that uses :cont pattern
  defcb chainable_callback(:stop), do: {:stopped, :at_service}
  defcb chainable_callback(value), do: {:cont, [value]}
end
