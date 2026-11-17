# Tracing and Instrumentation

`Malla.Tracer` is an instrumentation API for your services: spans, logs, metrics and events. It is technology-agnostic: you instrument your code once, and what happens to the spans and logs is decided by the plugin that implements the `malla_span*` callbacks. Without one, the default implementation logs through `Logger` and emits `:telemetry` events.

The point is that you can **instrument your code** while you write it, without committing to a specific backend (OpenTelemetry, Datadog, ...). That decision **can be deferred**: adding a tracer plugin to the service changes where the data goes, not your instrumented code.

How much it costs: every `span`, `metric`, `event` and log call is a callback call (through the callback chain of the service), and the log macros evaluate their message lazily. The only calls that disappear from the compiled code are the log macros (`debug`, `info`, `notice`, `warning`, `error`) below the compile-time `config :malla, log_min_level:` (see below).

## Quick Start

To use the tracer, list `Malla.Plugins.Tracer` in the `plugins:` of the service and `use Malla.Tracer` in the module you instrument. Without the plugin, the first `span` fails with `UndefinedFunctionError` for `malla_span/3`.

```elixir
defmodule MyService do
  use Malla.Service, plugins: [Malla.Plugins.Tracer]
  use Malla.Tracer # Import the tracer macros

  defcb process_payment(user_id, amount) do
    # 'span' creates a new trace span for this unit of work
    span [:payment, :process] do
      # 'info' creates a log entry
      info("Processing payment", user_id: user_id, amount: amount)

      case charge_card(user_id, amount) do
        {:ok, receipt} ->
          # 'metric' records a numerical value
          metric(:payments_successful, 1)
          {:ok, receipt}

        {:error, reason} = err ->
          # 'error/2' logs an error message
          error("Payment failed", reason: reason)
          metric(:payments_failed, 1)

          # 'error/1' with a value that is not a string marks the span as failed
          # and returns the value
          error(err)
      end
    end
  end

  defp charge_card(_user_id, amount) when amount > 0, do: {:ok, :receipt}
  defp charge_card(_user_id, _amount), do: {:error, :invalid_amount}
end
```

### The service ID

Every tracer call needs to know which service's callbacks to use, and takes it from the process dictionary (or, for `span/3`, from the `:service_id` option). If there is none, it raises `Malla.ServiceIdMissing`.

The example above is a `defcb`, and calling a callback sets the service ID. A plain `def` of the service that you call directly from IEx or from another process has no service ID: set it first with `Malla.put_service_id(MyService)`, pass `service_id: MyService` to `span/3`, call the function through `Malla.local/3`, or configure `config :malla, default_service_id: MyService` as a fallback.

## How It Works: The Plugin System

-   **Default behavior**: `Malla.Plugins.Tracer` provides default implementations of every callback. A span emits two `:telemetry` events, a log goes to the Elixir `Logger`, `metric/3` emits a `:telemetry` event, and the rest do nothing (see "What the default implementation does").
-   **With a tracer plugin**: a plugin that depends on `Malla.Plugins.Tracer` overrides the callbacks it wants, and your `span`, `info` and `metric` calls reach it. See "Custom Tracing with Plugins".

## Tracer API

All the macros and functions come with `use Malla.Tracer`.

### Spans
Spans represent a unit of work and can be nested.

-   `span(name, opts \\ [], do: block)`: executes the block within a span and returns its value. `name` is usually a list of atoms. `opts` are passed to the tracer plugin; `:service_id` selects the service.
-   `span_update(attributes)`: updates the current span with attributes.

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
Log macros call the `malla_span_log/3` callback; the module and line are added to the metadata.

-   `debug(message, metadata \\ [])`
-   `info(message, metadata \\ [])`
-   `notice(message, metadata \\ [])`
-   `warning(message, metadata \\ [])`
-   `error(message, metadata)` and `error(string)`: log at error level.
-   `error(term)`: when the argument is not a string, it calls `malla_span_error/2` to mark the current span as failed and returns the term.

The message is evaluated lazily, only when the tracer plugin calls the function it receives.

#### Compile-Time Filtering
Set a minimum log level in your configuration to remove the log macros below it from the compiled code:

```elixir
# In config/prod.exs
config :malla, log_min_level: :info # removes every `debug` call
```

The setting is read when each module that calls the log macros is compiled, so recompile those modules after changing it. Levels, lowest first: `:min`, `:debug`, `:metric`, `:info`, `:event`, `:notice`, `:warning`, `:error`, `:max`; a macro is kept if its level is at least the minimum. Nothing else is removed: spans, metrics, events and `error(term)` are still callback calls.

### Metrics and Events
- `metric(name, value, metadata \\ [])`: records a numerical value through `malla_span_metric/3`.
- `event(name, data \\ [], metadata \\ [])`: records a structured event within a span through `malla_span_event/3`.
- `labels(labels)` and `globals(attributes)`: set labels for the current span, and attributes that apply to all spans. They call `malla_span_labels/1` and `malla_span_globals/1`; the default implementations do nothing.
- `get_info(opts \\ [])`: asks the tracer for information about the current span; the default returns `nil`.

`Malla.metric/4` is the lower-level function behind `metric/3`: it executes `:telemetry` with the given class and value, and adds the metadata of the service (`:cluster`, `:node`, `:host`, `:service`) to your metadata.

```elixir
Malla.metric([:my_app, :orders], %{count: 3}, %{region: "eu"}, service_id: MyService)
# :telemetry.execute([:my_app, :orders], %{count: 3}, %{region: "eu", service: "MyService", ...})
```

A number as the value becomes `%{value: number}`; the class can be an atom (wrapped in a list) or a list. Without a service ID, the metadata has an empty `:service`.

## What the default implementation does

`Malla.Plugins.Tracer` implements each callback so that your code works without a tracer plugin:

| Call | Callback | Default |
| :--- | :--- | :--- |
| `span` | `malla_span/3` | Emits `[:malla, :tracer, :starts]` with measurements `%{counter: 1}` and metadata `span_name` and `opts`; runs the block; emits `[:malla, :tracer, :stops]` with `%{counter: 1}` and metadata `span_name` and `result`; returns the value of the block. |
| `span_update` | `malla_span_update/1` | Nothing. |
| `metric` | `malla_span_metric/3` | `Malla.metric([:malla, :tracer, name], data, meta)`: a `:telemetry` event. |
| `event` | `malla_span_event/3` | Nothing. |
| `debug`, `info`, ... | `malla_span_log/3` | `Logger.bare_log/3` at the corresponding level, with the metadata. |
| `error(term)` | `malla_span_error/2` | Returns the term. |
| `labels`, `globals` | `malla_span_labels/1`, `malla_span_globals/1` | Nothing. |
| `get_info` | `malla_span_info/1` | `nil`. |
| `get_base` | `malla_span_get_base/0` | `nil`. |

The default span does **not** measure the duration, and if the block raises there is no `:stops` event: the exception goes up to the caller. The telemetry metadata also carries the `:cluster`, `:node`, `:host` and `:service` fields of the service.

```elixir
:telemetry.attach_many(
  "spans",
  [[:malla, :tracer, :starts], [:malla, :tracer, :stops]],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata.span_name})
  end,
  nil
)
```

### Context Propagation
`Malla.Tracer` does not propagate anything by itself. Trace context crosses nodes only through the [request protocol](../08-distribution/04-request-handling.md): `Malla.Request.request/4` calls `get_base/0` (that is, `malla_span_get_base/0`) and passes the result as `:base_span` to the called service, which opens its `request-in` span with `base: <that value>` in the span options. `Malla.remote/4`, `Malla.Node` calls and virtual modules do not carry any context.

If you need to continue a trace in a process you spawn yourself, or hand the context to some external system, use `get_base/0` in the parent and give the value to the tracer plugin through the `:base` option of `span/3`, if your tracer supports it. What the context looks like, and what `:base` does, is defined by the tracer plugin.

## Custom Tracing with Plugins

You can write your own tracer plugin to integrate any backend. A tracing plugin is a standard Malla plugin that implements one or more of the `malla_span_*` callbacks defined in `Malla.Plugins.Tracer`.

It must declare `plugin_deps: [Malla.Plugins.Tracer]`. A plugin sits above the plugins it depends on; without the dependency it could end up below `Malla.Plugins.Tracer`, whose default `malla_span/3` returns a final value and never calls the plugins below it.

```elixir
defmodule MyApp.LogTracer do
  use Malla.Plugin, plugin_deps: [Malla.Plugins.Tracer]
  require Logger

  # Override the 'malla_span' callback: it must run the function it receives
  defcb malla_span(name, opts, fun) do
    started = System.monotonic_time(:microsecond)

    try do
      fun.()
    after
      elapsed = System.monotonic_time(:microsecond) - started
      Logger.debug("span #{inspect(name)} took #{elapsed} us (base: #{inspect(opts[:base])})")
    end
  end

  # Observe the logs and still let the default implementation handle them
  defcb malla_span_log(level, text_fun, _meta) do
    send(MyApp.LogCollector, {:log, level, text_fun.()})
    :cont
  end
end

defmodule MyService do
  use Malla.Service, plugins: [MyApp.LogTracer]
  use Malla.Tracer
  # ...
end
```

`MyApp.LogTracer` brings in `Malla.Plugins.Tracer` through its dependency, so you only list your plugin. `malla_span/3` receives the name, the options of the call (`:base`, `:labels`, and anything else you pass to `span/3`) and a zero-arity function with the code of the block.

A sketch of an OpenTelemetry plugin:

```elixir
defmodule MyApp.OpenTelemetryPlugin do
  use Malla.Plugin, plugin_deps: [Malla.Plugins.Tracer]

  require OpenTelemetry.Tracer

  defcb malla_span(name, _opts, fun) do
    span_name = name |> List.wrap() |> Enum.join(".")

    OpenTelemetry.Tracer.with_span span_name do
      try do
        fun.()
      rescue
        e ->
          OpenTelemetry.Tracer.record_exception(e)
          OpenTelemetry.Tracer.set_status(:error, Exception.message(e))
          reraise e, __STACKTRACE__
      end
    end
  end
end
```

This sketch is not part of Malla and is not tested here; check the API of the OpenTelemetry library you use. To make it distributed, use the `:base` option that `Malla.Request` passes to `request-in` spans to attach the new span to the context you returned from `malla_span_get_base/0`.

## Related

- [Request Handling](../08-distribution/04-request-handling.md) - the protocol that propagates the trace context.
- `Malla.Plugins.Tracer` and `Malla.Tracer` - the callbacks and macros.
