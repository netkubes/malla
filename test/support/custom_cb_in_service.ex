defmodule CustomCbInPlugin do
  @moduledoc false
  # Plugin that customizes service_cb_in to add instrumentation and validation
  # Note: service_cb_in is called for both local and remote calls

  use Malla.Plugin

  # Override service_cb_in to add custom behavior
  defcb service_cb_in(fun, args, opts) do
    service_id = Malla.get_service_id!()

    # Check if function is allowed first (before storing)
    allowed_result =
      case Keyword.get(opts, :allowed_functions) do
        nil ->
          :ok

        allowed_list ->
          if fun in allowed_list do
            :ok
          else
            {:error, {:forbidden, "Function #{fun} is not in allowed list"}}
          end
      end

    # Only store and continue if allowed
    case allowed_result do
      :ok ->
        # Store call information in the service's ETS table
        call_info = %{
          function: fun,
          args: args,
          opts: opts,
          timestamp: System.system_time(:millisecond),
          caller_node: node()
        }

        # Get existing calls or initialize empty list
        calls = Malla.Service.get(service_id, :intercepted_calls, [])
        Malla.Service.put(service_id, :intercepted_calls, [call_info | calls])

        # Continue to actual function call
        :cont

      error ->
        # Return error directly (stops the chain)
        error
    end
  end
end

defmodule CustomCbInService do
  @moduledoc false
  # Test service that uses CustomCbInPlugin to intercept and instrument remote calls

  use Malla.Service,
    class: :test,
    global: true,
    plugins: [CustomCbInPlugin]

  # Regular function
  def add(a, b), do: a + b

  # Another regular function
  def multiply(a, b), do: a * b

  # Function to get intercepted calls
  def get_intercepted_calls() do
    Malla.Service.get(CustomCbInService, :intercepted_calls, [])
  end

  # Function to clear intercepted calls
  def clear_intercepted_calls() do
    Malla.Service.put(CustomCbInService, :intercepted_calls, [])
  end

  # Callback function
  defcb greet(name), do: "Hello, #{name}!"

  # Protected function (for testing authorization)
  def protected_function(), do: :secret_data
end
