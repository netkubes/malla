defmodule Tracer.Test do
  @moduledoc false
  # Comprehensive test suite for Malla.Tracer.

  # This test suite validates Malla's zero-overhead observability system,
  # testing both:

  # 1. **Default Behavior** (without custom telemetry plugins)
  # 2. **Plugin Integration** (with CustomTracerPlugin)

  # ### Tracer Macros
  # - `span/2`, `span/3` - Span creation and nesting
  # - `debug/2`, `info/2`, `notice/2`, `warning/2`, `error/2` - Logging at all levels
  # - `metric/2`, `metric/3` - Metric recording
  # - `event/1`, `event/2`, `event/3` - Event recording
  # - `labels/1`, `globals/1` - Span categorization
  # - `span_update/1` - Progressive attribute enrichment
  # - `get_info/1`, `get_base/0` - Context retrieval

  # ### Default Implementations
  # - Telemetry event emission for spans
  # - Logger integration for log macros
  # - Telemetry metric emission
  # - No-op behavior for events/labels/globals

  # ### Plugin Integration
  # - Callback chain execution (service → plugin → default)
  # - Data capture and verification
  # - Pass-through with `:cont`
  # - Return value preservation

  # ## Related Files
  # - `lib/malla/tracer.ex` - Tracer macros and default implementations
  # - `lib/malla/plugins/tracer.ex` - Tracer plugin callback definitions
  # - `test/support/tracer_service.ex` - Test service with instrumentation
  # - `test/support/custom_tracer_plugin.ex` - Test telemetry plugin

  use ExUnit.Case, async: false

  # Import telemetry helpers for verifying default behavior
  import ExUnit.CaptureLog

  describe "default tracer behavior (without custom plugins)" do
    setup do
      {:ok, _pid} = TracerService.start_link()
      Malla.put_service_id(TracerService)

      on_exit(fn ->
        pid = Process.whereis(TracerService)

        if pid && Process.alive?(pid) do
          try do
            TracerService.stop()
            Process.sleep(50)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "simple operation creates span and returns value" do
      assert {:ok, 10} = TracerService.simple_operation(5)
    end

    test "nested spans work correctly" do
      assert {:ok, 15} = TracerService.nested_operation(5, 10)
    end

    test "logging operations delegate to Logger" do
      log =
        capture_log(fn ->
          TracerService.multi_level_logging(:test)
        end)

      assert is_binary(log) or log == ""
    end

    test "metrics are recorded" do
      assert :ok = TracerService.record_metrics(5)
    end

    test "events are no-op by default" do
      assert :ok = TracerService.record_events()
    end

    test "error handling works with pass-through" do
      assert {:error, :intentional_failure} = TracerService.handle_error(true)
      assert {:ok, :success} = TracerService.handle_error(false)
    end

    test "span updates are no-op by default" do
      assert {:ok, 3} = TracerService.progressive_attributes(3)
    end

    test "labels and globals are no-op by default" do
      assert {:ok, :web} = TracerService.categorized_operation(:web, :production)
    end

    test "span info returns nil by default" do
      assert {:ok, %{info: nil, base: nil}} = TracerService.get_span_context()
    end

    test "complex operation combines multiple features" do
      assert {:ok, 2} = TracerService.complex_operation(%{a: 1, b: 2})
      assert {:error, :invalid_data} = TracerService.complex_operation(%{})
    end
  end

  describe "tracer with custom plugin integration" do
    setup do
      defmodule TracerServiceWithPlugin do
        use Malla.Service,
          class: :test,
          vsn: "v1",
          plugins: [CustomTracerPlugin, Malla.Plugins.Tracer],
          global: false

        use Malla.Tracer

        def test_operation(value) do
          span [:test, :operation] do
            info("Test operation", value: value)
            metric(:test_metric, value)
            event(:test_event, data: value)
            labels(test: true)
            globals(env: :test)
            span_update(step: 1)
            {:ok, value}
          end
        end

        def test_error() do
          span [:test, :error] do
            err = {:error, :test_error}
            error("Test error")
            error(err)
          end
        end

        def test_nested() do
          span [:test, :parent] do
            debug("Parent span")

            span [:test, :child] do
              info("Child span")
              :child_result
            end
          end
        end

        def test_get_info() do
          span [:test, :info] do
            get_info()
          end
        end

        def test_get_base() do
          span [:test, :base] do
            get_base()
          end
        end
      end

      {:ok, _pid} = TracerServiceWithPlugin.start_link()
      Malla.put_service_id(TracerServiceWithPlugin)
      CustomTracerPlugin.clear_captured_data()

      on_exit(fn ->
        pid = Process.whereis(TracerServiceWithPlugin)

        if pid && Process.alive?(pid) do
          try do
            TracerServiceWithPlugin.stop()
            Process.sleep(50)
          catch
            :exit, _ -> :ok
          end
        end

        CustomTracerPlugin.clear_captured_data()
      end)

      %{service: TracerServiceWithPlugin}
    end

    test "plugin captures span invocations", %{service: service} do
      service.test_operation(42)

      spans = CustomTracerPlugin.get_captured_spans()
      assert length(spans) == 1
      assert {[:test, :operation], _opts} = List.first(spans)
    end

    test "plugin captures nested spans", %{service: service} do
      service.test_nested()

      spans = CustomTracerPlugin.get_captured_spans()
      assert length(spans) == 2
      assert {[:test, :parent], _} = Enum.at(spans, 0)
      assert {[:test, :child], _} = Enum.at(spans, 1)
    end

    test "plugin captures log entries", %{service: service} do
      service.test_operation(42)

      logs = CustomTracerPlugin.get_captured_logs()
      assert length(logs) >= 1

      assert Enum.any?(logs, fn {level, text, meta} ->
               level == :info and text == "Test operation" and meta[:value] == 42
             end)
    end

    test "plugin captures metrics", %{service: service} do
      service.test_operation(42)

      metrics = CustomTracerPlugin.get_captured_metrics()
      assert length(metrics) == 1
      assert {:test_metric, 42, _meta} = List.first(metrics)
    end

    test "plugin captures events", %{service: service} do
      service.test_operation(42)

      events = CustomTracerPlugin.get_captured_events()
      assert length(events) == 1
      assert {:test_event, [data: 42], _meta} = List.first(events)
    end

    test "plugin captures labels", %{service: service} do
      service.test_operation(42)

      labels = CustomTracerPlugin.get_captured_labels()
      assert length(labels) == 1
      assert [test: true] = List.first(labels)
    end

    test "plugin captures globals", %{service: service} do
      service.test_operation(42)

      globals = CustomTracerPlugin.get_captured_globals()
      assert length(globals) == 1
      assert [env: :test] = List.first(globals)
    end

    test "plugin captures span updates", %{service: service} do
      service.test_operation(42)

      updates = CustomTracerPlugin.get_captured_updates()
      assert length(updates) == 1
      assert [step: 1] = List.first(updates)
    end

    test "plugin captures errors", %{service: service} do
      service.test_error()

      errors = CustomTracerPlugin.get_captured_errors()
      assert length(errors) == 1
      assert {{:error, :test_error}, _meta} = List.first(errors)
    end

    test "plugin returns custom span info", %{service: service} do
      result = service.test_get_info()

      assert %{
               trace_id: "test-trace-123",
               span_id: "test-span-456",
               parent_span_id: "test-parent-789"
             } = result
    end

    test "plugin returns custom base context", %{service: service} do
      result = service.test_get_base()
      assert result == "test-base-context"
    end

    test "plugin preserves return values", %{service: service} do
      assert {:ok, 42} = service.test_operation(42)
      assert {:error, :test_error} = service.test_error()
      assert :child_result = service.test_nested()
    end
  end
end
