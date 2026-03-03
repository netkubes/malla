defmodule CustomTracerPlugin do
  @moduledoc false
  # Custom telemetry plugin for testing Malla.Tracer callback overrides.

  # This plugin overrides tracer callbacks to capture instrumentation data
  # in the process dictionary for test verification. It demonstrates how
  # telemetry backends can integrate with Malla's tracer system.

  # **Position in chain:**
  # TracerService → CustomTracerPlugin → Malla.Plugins.Tracer → Malla.Plugins.Base

  # The plugin stores instrumentation data in the process dictionary:
  # - `:tracer_spans` - List of span invocations
  # - `:tracer_logs` - List of log entries
  # - `:tracer_metrics` - List of metric recordings
  # - `:tracer_events` - List of span events
  # - `:tracer_errors` - List of error recordings
  # - `:tracer_labels` - List of label sets
  # - `:tracer_globals` - List of global attribute sets
  # - `:tracer_updates` - List of span updates

  use Malla.Plugin

  ## ===================================================================
  ## Callback Overrides
  ## ===================================================================

  defcb malla_span(name, opts, _fun) do
    capture_span(name, opts)
    # Continue to default implementation
    :cont
  end

  defcb malla_span_update(update) do
    capture_update(update)
    :cont
  end

  defcb malla_span_metric(id, value, meta) do
    capture_metric(id, value, meta)
    :cont
  end

  defcb malla_span_event(type, data, meta) do
    capture_event(type, data, meta)
    :ok
  end

  defcb malla_span_log(level, text, meta) do
    # Evaluate lazy text functions
    text_str = if is_function(text), do: text.(), else: text
    capture_log(level, text_str, meta)
    :cont
  end

  defcb malla_span_error(error, meta) do
    capture_error(error, meta)
    error
  end

  defcb malla_span_labels(labels) do
    capture_labels(labels)
    :cont
  end

  defcb malla_span_globals(globals) do
    capture_globals(globals)
    :cont
  end

  defcb malla_span_info(_opts) do
    %{
      trace_id: "test-trace-123",
      span_id: "test-span-456",
      parent_span_id: "test-parent-789"
    }
  end

  defcb malla_span_get_base() do
    "test-base-context"
  end

  ## ===================================================================
  ## Capture Functions (Private)
  ## ===================================================================

  defp capture_span(name, opts) do
    spans = Process.get(:tracer_spans, [])
    Process.put(:tracer_spans, spans ++ [{name, opts}])
  end

  defp capture_update(update) do
    updates = Process.get(:tracer_updates, [])
    Process.put(:tracer_updates, updates ++ [update])
  end

  defp capture_metric(id, value, meta) do
    metrics = Process.get(:tracer_metrics, [])
    Process.put(:tracer_metrics, metrics ++ [{id, value, meta}])
  end

  defp capture_event(type, data, meta) do
    events = Process.get(:tracer_events, [])
    Process.put(:tracer_events, events ++ [{type, data, meta}])
  end

  defp capture_log(level, text, meta) do
    logs = Process.get(:tracer_logs, [])
    Process.put(:tracer_logs, logs ++ [{level, text, meta}])
  end

  defp capture_error(error, meta) do
    errors = Process.get(:tracer_errors, [])
    Process.put(:tracer_errors, errors ++ [{error, meta}])
  end

  defp capture_labels(labels) do
    all_labels = Process.get(:tracer_labels, [])
    Process.put(:tracer_labels, all_labels ++ [labels])
  end

  defp capture_globals(globals) do
    all_globals = Process.get(:tracer_globals, [])
    Process.put(:tracer_globals, all_globals ++ [globals])
  end

  ## ===================================================================
  ## Public Accessors for Tests
  ## ===================================================================

  @doc "Retrieve captured span invocations"
  def get_captured_spans(), do: Process.get(:tracer_spans, [])

  @doc "Retrieve captured span updates"
  def get_captured_updates(), do: Process.get(:tracer_updates, [])

  @doc "Retrieve captured metrics"
  def get_captured_metrics(), do: Process.get(:tracer_metrics, [])

  @doc "Retrieve captured events"
  def get_captured_events(), do: Process.get(:tracer_events, [])

  @doc "Retrieve captured log entries"
  def get_captured_logs(), do: Process.get(:tracer_logs, [])

  @doc "Retrieve captured errors"
  def get_captured_errors(), do: Process.get(:tracer_errors, [])

  @doc "Retrieve captured labels"
  def get_captured_labels(), do: Process.get(:tracer_labels, [])

  @doc "Retrieve captured globals"
  def get_captured_globals(), do: Process.get(:tracer_globals, [])

  @doc "Clear all captured data"
  def clear_captured_data() do
    Process.delete(:tracer_spans)
    Process.delete(:tracer_updates)
    Process.delete(:tracer_metrics)
    Process.delete(:tracer_events)
    Process.delete(:tracer_logs)
    Process.delete(:tracer_errors)
    Process.delete(:tracer_labels)
    Process.delete(:tracer_globals)
    :ok
  end
end
