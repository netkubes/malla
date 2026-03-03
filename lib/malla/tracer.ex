## -------------------------------------------------------------------
##
## Copyright (c) 2026 Carlos Gonzalez Florido.  All Rights Reserved.
##
## This file is provided to you under the Apache License,
## Version 2.0 (the "License"); you may not use this file
## except in compliance with the License.  You may obtain
## a copy of the License at
##
##   http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing,
## software distributed under the License is distributed on an
## "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
## KIND, either express or implied.  See the License for the
## specific language governing permissions and limitations
## under the License.
##
## -------------------------------------------------------------------

defmodule Malla.Tracer do
  @moduledoc """
  Provides a zero-overhead observability API for Malla services.

  `Malla.Tracer` allows you to instrument your code with _spans_, _logs_, and _metrics_
  without committing to a specific telemetry backend. The actual tracing implementation
  is provided by plugins and can be added later or even swapped with touching your code.

  The tracing system works inside a `Malla.Service`. You must include plugin `Malla.Plugins.Tracer` in
  your service (or maybe a more specific plugin with a real implementation). Then, on the module
  to instrument must do `use Malla.Tracer`.

  ## Included Macros and Functions

  When you use `use Malla.Tracer`, the following macros and functions are imported into your module:

  ### Macros
  - [`span/2`](`Malla.Tracer.span/2`) - Creates a tracing span around the given code block.
  - [`span/3`](`Malla.Tracer.span/3`) - Creates a tracing span with options around the given code block.
  - [`debug/1`](`Malla.Tracer.debug/1`) - Logs a debug-level message.
  - [`debug/2`](`Malla.Tracer.debug/2`) - Logs a debug-level message with metadata.
  - [`info/1`](`Malla.Tracer.info/1`) - Logs an info-level message.
  - [`info/2`](`Malla.Tracer.info/2`) - Logs an info-level message with metadata.
  - [`event/1`](`Malla.Tracer.event/1`) - Records a tracing event.
  - [`event/2`](`Malla.Tracer.event/2`) - Records a tracing event with data.
  - [`notice/1`](`Malla.Tracer.notice/1`) - Logs a notice-level message.
  - [`notice/2`](`Malla.Tracer.notice/2`) - Logs a notice-level message with metadata.
  - [`warning/1`](`Malla.Tracer.warning/1`) - Logs a warning-level message.
  - [`warning/2`](`Malla.Tracer.warning/2`) - Logs a warning-level message with metadata.
  - [`error/1`](`Malla.Tracer.error/1`) - Logs an error-level message.
  - [`error/2`](`Malla.Tracer.error/2`) - Logs an error-level message with metadata.

  ### Functions
  - [`span_update/1`](`Malla.Tracer.span_update/1`) - Updates the current tracing span with new data.
  - [`metric/2`](`Malla.Tracer.metric/2`) - Records a metric value.
  - [`metric/3`](`Malla.Tracer.metric/3`) - Records a metric value with metadata.
  - [`labels/1`](`Malla.Tracer.labels/1`) - Sets labels on the current tracing span.
  - [`globals/1`](`Malla.Tracer.globals/1`) - Sets global tracing metadata.
  - [`get_info/0`](`Malla.Tracer.get_info/0`) - Retrieves current tracing information.
  - [`get_info/1`](`Malla.Tracer.get_info/1`) - Retrieves current tracing information with options.
  - [`get_base/0`](`Malla.Tracer.get_base/0`) - Gets base tracing configuration.

  For comprehensive documentation, see the guide:
  - **[Tracing and Instrumentation](guides/09-observability/01-tracing.md)**: For a guide on how to use the tracer.
  """

  ## ===================================================================
  ## Macros
  ## ===================================================================

  defmacro __using__(_options) do
    quote do
      import Malla.Tracer,
        only: [
          span: 2,
          span: 3,
          span_update: 1,
          # spawn_span: 2,
          # spawn_span: 3,
          debug: 1,
          debug: 2,
          metric: 2,
          metric: 3,
          info: 1,
          info: 2,
          event: 1,
          event: 2,
          notice: 1,
          notice: 2,
          warning: 1,
          warning: 2,
          error: 1,
          error: 2,
          labels: 1,
          globals: 1,
          get_info: 0,
          get_info: 1,
          get_base: 0
        ]
    end
  end

  @type id :: atom
  @type span_id :: [atom]
  @type data :: keyword | map
  @type level_name ::
          :min | :debug | :info | :metric | :event | :notice | :warning | :error | :max
  @type level_code :: 0..9

  @doc """
  Execute code within a span context.

  Spans represent units of work in your distributed system. They can be nested
  and provide context for all logs, metrics, and events that occur during execution.

  ## Parameters

  - `name` - Span identifier, either an atom or list of atoms (e.g., `[:payment, :process]`)
  - `opts` - Keyword list of options (including optional `:service_id`)
  - `block` - Code to execute within the span

  ## Service ID Resolution

  Every span must be linked to a specific _service_id_ (see `t:Malla.id/0`),
  since it will be used to call the corresponding callbacks. In order to find it,
  we will try to extract key `:service_id` from _opts_, or, if not there, from
  process dictionary calling `Malla.get_service_id!()`. If not found,
  it will raise `Malla.ServiceIdMissing`.

  Current service ID is now inserted in process dictionary calling
  `Malla.put_service_id/1`.

  The macro will call callback `c:Malla.Plugins.Tracer.malla_span/3`.
  If not overriden, it will simply execute the code and add some telemetry events.

  ## Examples

      # Simple span with service_id from process dictionary
      span [:database, :query] do
        Repo.all(User)
      end

      # Span with explicit service_id
      span [:payment, :charge], service_id: PaymentService do
        charge_card(amount)
      end

      # Nested spans
      span [:parent] do
        info("Parent operation")

        span [:child] do
          info("Child operation")
        end
      end
  """

  @spec span(span_id, keyword, keyword) :: any
  defmacro span(name, opts, do: code) do
    quote do
      fun = fn -> unquote(code) end
      srv_id = Malla.get_service_id!(unquote(opts))
      Malla.local(srv_id, :malla_span, [unquote(name), unquote(opts), fun])
    end
  end

  @doc """
  Execute code within a span context.

  This is a convenience macro equivalent to `span/3` without options.
  Since there are no options, service_id must be present in process dictionary.

  Calls callback `c:Malla.Plugins.Tracer.malla_span/3`. Default implementation emits telemetry events for span start and stop.

  ## Example

      span [:api_request] do
        handle_request(conn)
      end
  """

  @spec span(span_id, keyword) :: any
  defmacro span(name, do: code) do
    quote do
      fun = fn -> unquote(code) end
      srv_id = Malla.get_service_id!()
      Malla.local(srv_id, :malla_span, [unquote(name), [], fun])
    end
  end

  @doc """
  Update attributes of the current span.

  Adds or updates metadata on the active span. This is useful for adding
  contextual information discovered during span execution.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_update/1`. Default implementation does nothing.

  ## Examples

      span [:api_request] do
        span_update(user_id: 123, request_id: uuid)
        process_request()
      end

      span [:database, :query] do
        span_update(table: "users", operation: "select")
        result = execute_query()
        span_update(row_count: length(result))
        result
      end
  """

  @spec span_update(keyword) :: :ok
  def span_update(update), do: Malla.local(:malla_span_update, [update])

  @doc """
  Record a metric value.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_metric/3`. Default implementation sends the metric to `:telemetry`.

  ## Examples

      # Simple counter
      metric(:requests_processed, 1)

      # Duration metric with metadata
      metric(:query_duration, %{duration: 150}, %{table: "users"})

      # Multiple values
      metric(:cache_stats, hits: 10, misses: 2)

      # Within a span
      span [:payment] do
        process_payment()
        metric(:payments_successful, 1)
      end
  """

  @spec metric(id, number | data, data) :: :ok
  def metric(id, data, meta \\ []), do: Malla.local(:malla_span_metric, [id, data, meta])

  @doc """
  Record a span event.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_event/3`. Default implementation does nothing.

  Events represent discrete occurrences within a span (e.g., cache hit, retry attempt,
  external API call). They differ from logs in that they're structured data points.

  ## Parameters

  - `type` - Event type identifier (atom)
  - `data` - Event data (keyword list or map, optional)
  - `meta` - Additional metadata (keyword list or map, optional)

  ## Examples

      span [:api_request] do
        event(:cache_hit, key: "user:123")
        # ... later ...
        event(:validation_passed, fields: ["email", "name"])
      end

      # Retry event
      event(:retry_attempt, attempt: 3, delay_ms: 1000)

      # External service call
      event(:external_call, service: "payment_gateway", duration_ms: 250)

  """

  @spec event(id, data, data) :: Macro.t()
  defmacro event(type, data \\ [], meta \\ []) do
    quote do
      Malla.local(:malla_span_event, [unquote(type), unquote(data), unquote(meta)])
    end
  end

  @doc """
  Log a debug-level message.

  Debug logs are intended for development and troubleshooting. They can be
  completely removed at compile time by setting `:log_min_level` above `:debug`.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_log/3`. Default implementation delegates to `Logger`.

  ## Parameters

  - `text` - Log message (supports string interpolation)
  - `meta` - Additional metadata (keyword list or map, optional)

  ## Examples

      debug("User lookup: 123", user_id: 123)
      debug("Cache stats", hits: 10, misses: 2)

  ## Compile-Time Filtering

      # config/prod.exs
      config :malla, log_min_level: :info  # Removes debug() calls completely

  ## Auto-Injected Metadata

  - `:module` - Current module name
  - `:line` - Line number in source file

  """
  @spec debug(String.t(), data) :: Macro.t()
  defmacro debug(text, meta \\ []) do
    if is_compile_level?(:debug), do: macro_log(:debug, text, meta, __CALLER__)
  end

  @doc """
  Log an info-level message.

  Info logs represent general informational messages about system operation.

  ## Examples

      info("Payment processed", amount: 100, currency: "USD")
      info("User logged in", user_id: 123, ip: "1.2.3.4")

  See `debug/2` for detailed documentation on behavior and configuration.
  """
  @spec info(String.t(), data) :: Macro.t()
  defmacro info(text, meta \\ []) do
    if is_compile_level?(:info), do: macro_log(:info, text, meta, __CALLER__)
  end

  @doc """
  Log a notice-level message.

  Notice logs represent significant but normal events that are noteworthy.

  ## Examples

      notice("Service configuration updated", changes: ["timeout", "retries"])
      notice("Leader election completed", new_leader: node())

  See `debug/2` for detailed documentation on behavior and configuration.
  """
  @spec notice(String.t(), data) :: Macro.t()
  defmacro notice(text, meta \\ []) do
    if is_compile_level?(:notice), do: macro_log(:notice, text, meta, __CALLER__)
  end

  @doc """
  Log a warning-level message.

  Warning logs indicate potentially problematic situations that should be investigated.

  ## Examples

      warning("Retry attempt 3", max_retries: 5, attempt: 3)
      warning("High memory usage", usage_mb: 1024)

  See `debug/2` for detailed documentation on behavior and configuration.
  """
  @spec warning(String.t(), data) :: Macro.t()
  defmacro warning(text, meta \\ []) do
    if is_compile_level?(:warning), do: macro_log(:warning, text, meta, __CALLER__)
  end

  @doc """
  Log an error-level message.

  Error logs indicate error conditions that require attention.

  ## Examples

      error("Payment failed", reason: :insufficient_funds, user_id: 123)
      error("Database connection lost", attempts: 3)

  See `debug/2` for detailed documentation on behavior and configuration.
  """
  @spec error(String.t(), data) :: Macro.t()

  defmacro error(text, meta) do
    if is_compile_level?(:error), do: macro_log(:error, text, meta, __CALLER__)
  end

  @doc """
  Mark the current span as error or log an error message.

  This function is overloaded to support two use cases:

  1. **Log an error message**: When called with a string, logs at error level.
  2. **Mark span as error**: When called with any other value, records the error
     in the span context and returns the value unchanged (passthrough).

  Calls callback `c:Malla.Plugins.Tracer.malla_span_error/2` for non-string values. Default implementation returns the error unchanged.

  ## Parameters

  - `error` - Error value (typically `{:error, reason}`) or string message

  ## Examples

      # Mark span as error (passthrough pattern)
      span [:payment] do
        case charge_card(amount) do
          {:ok, result} -> result
          {:error, _} = err -> error(err)  # Mark span, return error
        end
      end

      # Pipeline usage
      {:error, :timeout}
      |> error()
      |> handle_payment_error()

      # String variant logs an error
      error("Connection failed")  # Same as error("Connection failed", [])

  """
  @spec error(any) :: Macro.t()

  # Complex string are capture here
  defmacro error({:<<>>, _, _} = text), do: macro_log(:error, text, [], __CALLER__)

  # Normal strings
  defmacro error(text) when is_binary(text), do: macro_log(:error, text, [], __CALLER__)

  defmacro error(error) do
    %{file: _file, line: line} = __CALLER__

    quote bind_quoted: [error: error, line: line] do
      meta = [{:module, __MODULE__}, {:line, line}]
      Malla.local(:malla_span_error, [error, meta])
    end
  end

  @doc """
  Set labels on the current span.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_labels/1`. Default implementation does nothing.

  Labels are key-value pairs that categorize spans for filtering and aggregation.

  ## Parameters

  - `labels` - Keyword list or map of labels

  ## Examples

      span [:api_request] do
        labels(user_type: "premium", region: "us-east", version: "v2")
        process_request()
      end
  """
  @spec labels(data) :: :ok
  def labels(labels), do: Malla.local(:malla_span_labels, [labels])

  @doc """
  Set global attributes that apply to all spans in this context.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_globals/1`. Default implementation does nothing.

  Globals are useful for deployment-wide or service-wide attributes
  set once rather than on every span.

  ## Parameters

  - `map` - Keyword list or map of global attributes

  ## Examples

      # Set once at service startup
      globals(deployment: "production", version: "1.2.3", datacenter: "us-east")

      span [:request] do
        # Globals automatically included in this and all nested spans
        process_request()
      end
  """
  @spec globals(data) :: :ok
  def globals(map), do: Malla.local(:malla_span_globals, [map])

  @doc """
  Retrieve information about the current span.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_info/1`. Default implementation returns `nil`.

  Returns metadata about the active span context.

  """
  @spec get_info(keyword) :: map | nil
  def get_info(opts \\ []), do: Malla.local(:malla_span_info, [opts])

  @doc """
  Get the base span context for propagation.

  Returns the current span context that can be used to propagate tracing
  information to remote services or child processes, enabling distributed tracing.

  Calls callback `c:Malla.Plugins.Tracer.malla_span_get_base/0`. Default implementation returns `nil`.

  ## Returns

  Opaque span context value (format depends on telemetry plugin), or `nil` if no span is active.

  ## Examples

      # Parent process
      span [:parent] do
        base = get_base()

        Task.async(fn ->
          # Child process - would restore context with set_base/1
          # (set_base/1 would be implemented by telemetry plugin)
          do_work()
        end)
      end

      # HTTP client - propagate to remote service
      span [:api_call] do
        base = get_base()
        headers = inject_trace_context(base)  # Plugin-specific
        HTTPClient.get(url, headers: headers)
      end

  """
  @spec get_base() :: any
  def get_base(), do: Malla.local(:malla_span_get_base, [])

  # def set_base(base), do: Malla.local(:malla_span_set_base, [base])

  ## ===================================================================
  ## Internal
  ## ===================================================================

  @doc false
  defp macro_log(level, text, data, caller) do
    %{file: _file, line: line} = caller

    quote do
      data = unquote(data)
      data = if is_map(data), do: Map.to_list(data), else: data

      data = [
        {:module, __MODULE__},
        {:line, unquote(line)}
        | data
      ]

      Malla.local(:malla_span_log, [unquote(level), fn -> unquote(text) end, data])
    end
  end

  defp is_compile_level?(level) do
    compile_min_level = Application.get_env(:malla, :log_min_level, :min)
    name_to_level(level) >= name_to_level(compile_min_level)
  end

  @level_min 0
  @level_debug 1
  @level_metric 2
  @level_info 3
  @level_event 4
  @level_notice 5
  @level_warning 6
  @level_error 7
  @level_max 9

  @doc """
  Translates a level name to its corresponding numeric code.
  """
  @spec name_to_level(level_name | level_code) :: level_code
  def name_to_level(:min), do: @level_min
  def name_to_level(:debug), do: @level_debug
  def name_to_level(:info), do: @level_info
  def name_to_level(:metric), do: @level_metric
  def name_to_level(:event), do: @level_event
  def name_to_level(:notice), do: @level_notice
  def name_to_level(:warning), do: @level_warning
  def name_to_level(:error), do: @level_error
  def name_to_level(:max), do: @level_max
  def name_to_level(level) when is_integer(level) and level >= 0 and level <= 9, do: level

  @doc """
  Translates a level code to its corresponding Elixir Logger level.
  """
  @spec level_to_logger(level_code) :: level_name
  def level_to_logger(@level_debug), do: :debug
  def level_to_logger(@level_metric), do: :debug
  def level_to_logger(@level_info), do: :info
  def level_to_logger(@level_event), do: :info
  def level_to_logger(@level_notice), do: :notice
  def level_to_logger(@level_warning), do: :warning
  def level_to_logger(@level_error), do: :error
  def level_to_logger(name) when is_atom(name), do: name_to_level(name) |> level_to_logger()

  # defp to_map(map) when is_map(map), do: map
  # defp to_map(tuple) when is_tuple(tuple), do: Map.new([tuple])
  # defp to_map(list) when is_list(list), do: Map.new(list)
end
