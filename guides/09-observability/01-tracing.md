# Tracing and Instrumentation

Malla includes a zero-overhead observability system called `Malla.Tracer`. It provides a technology-agnostic API for instrumenting your services with spans, logs, metrics, and events.

The key principle is that you can **instrument your code** while you write it, without committing to a specific telemetry backend (like OpenTelemetry or Datadog). That decision **can be deferred** and implemented later by adding a plugin, without changing any of your instrumented code.

## Quick Start

To use the tracer, `use Malla.Tracer` in your service module.

```elixir
defmodule MyService do
  use Malla.Service
  use Malla.Tracer # Import the tracer macros

  def process_payment(user_id, amount) do
    # 'span' creates a new trace span for this unit of work
    span [:payment, :process] do
      # 'info' creates a log entry associated with the span
      info("Processing payment", user_id: user_id, amount: amount)

      case charge_card(user_id, amount) do
        {:ok, receipt} ->
          # 'metric' records a numerical value
          metric(:payments_successful, 1)
          {:ok, receipt}
        
        {:error, reason} = err ->
          # 'error' logs an error message
          error("Payment failed", reason: reason)
          metric(:payments_failed, 1)
          
          # 'error/1' can also mark the span as having an error
          error(err)
      end
    end
  end
end
```

## How It Works: The Plugin System

-   **Default Behavior**: Without any special plugins, `Malla.Tracer` provides minimal functionality. Spans emit basic `:telemetry` events, and logs are sent to the standard Elixir `Logger`.
-   **With Plugins**: When you add a telemetry plugin (e.g., for OpenTelemetry), that plugin overrides the default tracer callbacks. Your `span`, `info`, and `metric` calls are then routed to the full-featured telemetry backend, enabling distributed tracing, rich context, and custom metrics. We will release soon a powerful plugin capable of sending all traces to Jaeger.

This allows you to add comprehensive observability to your application at any time just by adding a plugin to your service configuration.

## Tracer API

### Spans
Spans represent a unit of work and can be nested to create a detailed trace.

-   `span(name, opts, do: block)`: Executes the block of code within a new span. The `name` is typically a list of atoms.
-   `span_update(attributes)`: Updates the current span with new key-value attributes.

```elixir
span [:http, :request] do
  span_update(path: "/users", method: "GET")
  
  # Nested span
  span [:database, :query] do
    # ...
  end
end
```

### Logging
Log macros create structured log entries that are automatically associated with the current span. They also support compile-time log level filtering.

-   `debug(message, metadata \\ [])`
-   `info(message, metadata \\ [])`
-   `notice(message, metadata \\ [])`
-   `warning(message, metadata \\ [])`
-   `error(message, metadata \\ [])`
-   `error(error_term)`: Marks the current span with an error status.

#### Compile-Time Filtering
You can set a minimum log level in your configuration to completely remove log calls from your compiled code, ensuring zero performance impact in production.

```elixir
# In config/prod.exs
config :malla, log_min_level: :info # This will remove all `debug` calls
```

### Metrics and Events
- `metric(name, value, metadata \\ [])`: Records a numerical metric.
- `event(name, data \\ [], metadata \\ [])`: Records a structured event within a span, representing a point-in-time occurrence.

### Context Propagation
The tracer system works seamlessly with Malla's remote calls, automatically propagating trace context across nodes to enable distributed tracing.

For custom context propagation (e.g., to manually spawned processes or for integrating with external systems), you can use `get_base/0` to retrieve the current span context. A telemetry plugin would then provide a corresponding `set_base/1` function to restore that context in another process.

## Custom Tracing with Plugins

While Malla may provide official telemetry plugins in the future, you can create your own to integrate with any backend.

A tracing plugin is a standard Malla plugin that implements one or more of the `malla_span_*` callbacks defined in `Malla.Plugins.Tracer`.

Here is a simplified example for OpenTelemetry:

```elixir
defmodule OpenTelemetryPlugin do
  use Malla.Plugin
  
  # Override the 'malla_span' callback
  defcb malla_span(name, opts, fun) do
    # Convert Malla's span name to a string for OpenTelemetry
    span_name = Enum.join(List.wrap(name), ".")
    
    # Use the OpenTelemetry API to start a span
    OpenTelemetry.Tracer.with_span span_name do
      try do
        result = fun.()
        OpenTelemetry.Span.set_status(:ok)
        result
      rescue
        e ->
          OpenTelemetry.Span.record_exception(e)
          OpenTelemetry.Span.set_status(:error, Exception.message(e))
          reraise e, __STACKTRACE__
      end
    end
  end
  
  # Override the 'malla_span_log' callback to add logs as span events
  defcb malla_span_log(level, text_fun, meta) do
    text_str = text_fun.()
    OpenTelemetry.Span.add_event(text_str, Map.new(meta))
    
    # Continue the chain to also send the log to the default Elixir Logger
    :cont
  end
end
```

By adding this plugin to your service, all `span` and `log` calls will be sent to OpenTelemetry without any changes to your business logic.
