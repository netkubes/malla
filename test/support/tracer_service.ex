defmodule TracerService do
  @moduledoc false

  # Test service demonstrating Malla.Tracer usage patterns.
  #
  # This service uses `Malla.Tracer` to instrument operations with spans,
  # logs, metrics, and events. It serves as a test fixture for validating
  # both default tracer behavior and custom telemetry plugin integration.

  # The service can optionally include custom tracer plugins for testing
  # telemetry backend integration.

  use Malla.Service,
    class: :test,
    vsn: "v1",
    plugins: [Malla.Plugins.Tracer],
    global: false

  use Malla.Tracer

  def simple_operation(value) do
    span [:tracer_service, :simple] do
      info("Processing value", value: value)
      {:ok, value * 2}
    end
  end

  # Demonstrates span nesting where child spans inherit parent context.
  def nested_operation(a, b) do
    span [:tracer_service, :parent] do
      info("Parent operation started", a: a, b: b)

      result =
        span [:tracer_service, :child] do
          debug("Child operation processing")
          a + b
        end

      info("Parent operation complete", result: result)
      {:ok, result}
    end
  end

  # Operation that logs at different levels.
  def multi_level_logging(level) do
    span [:tracer_service, :logging] do
      debug("Debug level message", level: :debug)
      info("Info level message", level: :info)
      notice("Notice level message", level: :notice)
      warning("Warning level message", level: :warning)
      error("Error level message", level: :error)
      level
    end
  end

  # Operation that records metrics.

  def record_metrics(count) do
    span [:tracer_service, :metrics] do
      metric(:operation_count, count)
      metric(:operation_timing, %{duration: 100}, %{unit: "ms"})
      metric(:multi_value, hits: 5, misses: 2)
      :ok
    end
  end

  # Operation that records span events.
  def record_events() do
    span [:tracer_service, :events] do
      event(:cache_hit, key: "user:123")
      event(:retry_attempt, attempt: 1, delay_ms: 100)
      event(:external_call, service: "api", duration_ms: 50)
      :ok
    end
  end

  # Operation that handles errors.

  def handle_error(should_fail) do
    span [:tracer_service, :error_handling] do
      case should_fail do
        true ->
          err = {:error, :intentional_failure}
          error("Operation failed", reason: :intentional_failure)
          error(err)

        false ->
          info("Operation succeeded")
          {:ok, :success}
      end
    end
  end

  # Operation that uses span updates.
  def progressive_attributes(steps) do
    span [:tracer_service, :progressive] do
      span_update(total_steps: steps)

      Enum.each(1..steps, fn step ->
        span_update(current_step: step, progress: step / steps)
        debug("Processing step", step: step)
      end)

      span_update(status: :complete)
      {:ok, steps}
    end
  end

  # Operation that uses labels and globals.
  def categorized_operation(category, env) do
    globals(environment: env, service: "tracer_service")

    span [:tracer_service, :categorized] do
      labels(category: category, priority: :high)
      info("Categorized operation", category: category)
      {:ok, category}
    end
  end

  # Operation that retrieves span info.
  def get_span_context() do
    span [:tracer_service, :context] do
      info = get_info()
      base = get_base()
      {:ok, %{info: info, base: base}}
    end
  end

  # Complex operation combining multiple tracer features.
  def complex_operation(data) do
    span [:tracer_service, :complex], service_id: TracerService do
      labels(operation: :complex, data_type: "map")
      info("Complex operation started", data_size: map_size(data))

      event(:validation_start)

      case validate_data(data) do
        :ok ->
          event(:validation_passed)
          metric(:validations_passed, 1)

          result =
            span [:tracer_service, :processing] do
              span_update(data_keys: Map.keys(data))
              process_data(data)
            end

          info("Complex operation complete", result: result)
          metric(:operations_completed, 1)
          {:ok, result}

        {:error, reason} = err ->
          event(:validation_failed, reason: reason)
          metric(:validations_failed, 1)
          warning("Validation failed", reason: reason)
          error(err)
      end
    end
  end

  defp validate_data(data) when is_map(data) and map_size(data) > 0, do: :ok
  defp validate_data(_), do: {:error, :invalid_data}

  defp process_data(data) do
    debug("Processing data")
    Map.keys(data) |> length()
  end
end
