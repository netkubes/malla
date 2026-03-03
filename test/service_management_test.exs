defmodule Malla.ServiceManagementTest do
  @moduledoc false
  # Test suite for service management, status transitions, and lifecycle callbacks.
  #
  # Tests cover:
  # - Admin status changes (:active, :pause, :inactive)
  # - Running status transitions (:starting, :running, :pausing, :paused, :stopping, :stopped, :failed)
  # - service_status_changed/2 callback invocation and plugin chain
  # - service_is_ready?/0 callback and readiness checks
  # - service_drain/0 callback and drain completion logic
  # - Service lifecycle edge cases

  use ExUnit.Case, async: false

  require Logger

  # Plugin that tracks status changes
  defmodule TestPlugin1 do
    use Malla.Plugin

    defcb service_status_changed(status) do
      srv_id = Malla.get_service_id!()
      service = srv_id.service()

      changes = Malla.Service.get(srv_id, :status_changes, [])

      Malla.Service.put(
        srv_id,
        :status_changes,
        changes ++ [{__MODULE__, status, service}]
      )

      :cont
    end

    defcb service_is_ready?() do
      srv_id = Malla.get_service_id!()

      case Malla.Service.get(srv_id, :plugin1_ready, true) do
        true -> :cont
        false -> false
      end
    end

    defcb service_drain() do
      srv_id = Malla.get_service_id!()

      case Malla.Service.get(srv_id, :plugin1_drained, true) do
        true -> :cont
        false -> false
      end
    end
  end

  # Another plugin for callback chain testing
  defmodule TestPlugin2 do
    use Malla.Plugin, plugin_deps: [TestPlugin1]

    defcb service_status_changed(status) do
      srv_id = Malla.get_service_id!()
      service = srv_id.service()

      changes = Malla.Service.get(srv_id, :status_changes, [])

      Malla.Service.put(
        srv_id,
        :status_changes,
        changes ++ [{__MODULE__, status, service}]
      )

      :cont
    end

    defcb service_is_ready?() do
      srv_id = Malla.get_service_id!()

      case Malla.Service.get(srv_id, :plugin2_ready, true) do
        true -> :cont
        false -> false
      end
    end

    defcb service_drain() do
      srv_id = Malla.get_service_id!()

      case Malla.Service.get(srv_id, :plugin2_drained, true) do
        true -> :cont
        false -> false
      end
    end
  end

  # Test service that tracks status changes and implements drain/ready callbacks
  defmodule TestService do
    use Malla.Service,
      class: :test_management,
      vsn: "1.0.0",
      plugins: [TestPlugin1, TestPlugin2]

    # Track all status changes in ETS
    defcb service_status_changed(status) do
      srv_id = Malla.get_service_id!()
      service = srv_id.service()

      changes = Malla.Service.get(__MODULE__, :status_changes, [])
      Malla.Service.put(__MODULE__, :status_changes, changes ++ [{__MODULE__, status, service}])
      :cont
    end

    # Service is ready only if :service_ready flag is set
    defcb service_is_ready?() do
      case Malla.Service.get(__MODULE__, :service_ready, true) do
        true -> :cont
        false -> false
      end
    end

    # Service drain completion depends on :service_drained flag
    defcb service_drain() do
      case Malla.Service.get(__MODULE__, :service_drained, true) do
        true -> :cont
        false -> false
      end
    end
  end

  alias __MODULE__.TestService

  setup do
    # Clean up any running services from previous tests
    pid = Process.whereis(TestService)

    if pid && Process.alive?(pid) do
      try do
        TestService.stop()
        Process.sleep(100)
      catch
        _, _ -> :ok
      end
    end

    # Start fresh service
    {:ok, pid} = TestService.start_link([])
    Process.sleep(50)

    on_exit(fn ->
      pid = Process.whereis(TestService)

      if pid && Process.alive?(pid) do
        try do
          TestService.stop()
          Process.sleep(50)
        catch
          _, _ -> :ok
        end
      end
    end)

    {:ok, pid: pid}
  end

  describe "service_status_changed callback chain" do
    test "callback is invoked on service start with correct chain order" do
      # Clear status changes to track only new changes
      Malla.Service.put(TestService, :status_changes, [])

      # Trigger a status change
      :ok = TestService.set_admin_status(:pause, :test)
      Process.sleep(50)

      changes = Malla.Service.get(TestService, :status_changes, [])

      # Should have been called for all modules in plugin chain (top-down)
      # Chain order: TestService → TestPlugin1 → TestPlugin2 → Base
      assert length(changes) >= 3

      # Verify TestService was called first
      assert {TestService, :pausing, _service} = Enum.at(changes, 0)

      # Verify TestPlugin2 was called second (it depends on TestPlugin1)
      assert {TestPlugin2, :pausing, _service} = Enum.at(changes, 1)

      # Verify TestPlugin1 was called third
      assert {TestPlugin1, :pausing, _service} = Enum.at(changes, 2)

      # Verify service struct is passed correctly
      {_, _, service} = Enum.at(changes, 0)
      assert %Malla.Service{} = service
      assert service.id == TestService
      assert service.vsn == "1.0.0"
    end

    test "callback is invoked through all status transitions" do
      Malla.Service.put(TestService, :status_changes, [])

      # Transition: running → pausing → paused
      :ok = TestService.set_admin_status(:pause, :test)
      Process.sleep(50)

      changes = Malla.Service.get(TestService, :status_changes, [])
      statuses = Enum.map(changes, fn {_, status, _} -> status end) |> Enum.uniq()
      assert :pausing in statuses
      assert :paused in statuses

      # Transition: paused → starting → running
      Malla.Service.put(TestService, :status_changes, [])
      :ok = TestService.set_admin_status(:active, :test)
      Process.sleep(50)

      changes = Malla.Service.get(TestService, :status_changes, [])
      statuses = Enum.map(changes, fn {_, status, _} -> status end) |> Enum.uniq()
      assert :starting in statuses
      assert :running in statuses

      # Transition: running → stopping → stopped
      Malla.Service.put(TestService, :status_changes, [])
      :ok = TestService.set_admin_status(:inactive, :test)
      Process.sleep(50)

      changes = Malla.Service.get(TestService, :status_changes, [])
      statuses = Enum.map(changes, fn {_, status, _} -> status end) |> Enum.uniq()
      assert :stopping in statuses
      assert :stopped in statuses
    end

    test "callback receives service struct with correct metadata" do
      Malla.Service.put(TestService, :status_changes, [])

      :ok = TestService.set_admin_status(:pause, :metadata_test)
      Process.sleep(50)

      changes = Malla.Service.get(TestService, :status_changes, [])
      {_, _, service} = List.first(changes)

      assert %Malla.Service{} = service
      assert service.id == TestService
      assert service.vsn == "1.0.0"
      assert service.class == :test_management
    end
  end

  describe "admin status management" do
    test "set_admin_status changes from active to pause" do
      assert :running == TestService.get_status()

      :ok = TestService.set_admin_status(:pause, :test_pause)
      Process.sleep(50)

      assert :paused == TestService.get_status()

      {:ok, info} = Malla.Service.get_service_info(TestService)
      assert info.admin_status == :pause
      assert info.running_status == :paused
      assert info.last_status_reason == :test_pause
    end

    test "set_admin_status changes from active to inactive" do
      assert :running == TestService.get_status()

      :ok = TestService.set_admin_status(:inactive, :test_inactive)
      Process.sleep(50)

      assert :stopped == TestService.get_status()

      {:ok, info} = Malla.Service.get_service_info(TestService)
      assert info.admin_status == :inactive
      assert info.running_status == :stopped
      assert info.last_status_reason == :test_inactive
    end

    test "set_admin_status from pause to active restarts service" do
      :ok = TestService.set_admin_status(:pause, :test)
      Process.sleep(50)
      assert :paused == TestService.get_status()

      :ok = TestService.set_admin_status(:active, :resume)
      Process.sleep(50)

      assert :running == TestService.get_status()

      {:ok, info} = Malla.Service.get_service_info(TestService)
      assert info.admin_status == :active
      assert info.running_status == :running
      assert info.last_status_reason == :resume
    end

    test "set_admin_status from inactive to active restarts service" do
      :ok = TestService.set_admin_status(:inactive, :test)
      Process.sleep(50)
      assert :stopped == TestService.get_status()

      :ok = TestService.set_admin_status(:active, :restart)
      Process.sleep(50)

      assert :running == TestService.get_status()

      {:ok, info} = Malla.Service.get_service_info(TestService)
      assert info.admin_status == :active
      assert info.running_status == :running
    end

    test "set_admin_status with same status is idempotent" do
      Malla.Service.put(TestService, :status_changes, [])

      :ok = TestService.set_admin_status(:active, :same)
      Process.sleep(50)

      # No status change should have occurred
      changes = Malla.Service.get(TestService, :status_changes, [])
      assert changes == []
    end

    test "multiple rapid status changes are handled correctly" do
      :ok = TestService.set_admin_status(:pause, :first)
      :ok = TestService.set_admin_status(:active, :second)
      :ok = TestService.set_admin_status(:inactive, :third)
      :ok = TestService.set_admin_status(:active, :fourth)
      Process.sleep(100)

      assert :running == TestService.get_status()

      {:ok, info} = Malla.Service.get_service_info(TestService)
      assert info.admin_status == :active
      assert info.running_status == :running
    end
  end

  describe "running status tracking" do
    test "get_status returns current running status" do
      assert :running == TestService.get_status()

      :ok = TestService.set_admin_status(:pause, :test)
      Process.sleep(50)
      assert :paused == TestService.get_status()

      :ok = TestService.set_admin_status(:inactive, :test)
      Process.sleep(50)
      assert :stopped == TestService.get_status()
    end

    test "get_status returns :unknown for non-existent service" do
      assert :unknown == Malla.Service.get_status(NonExistentService)
    end

    test "get_service_info returns complete service information" do
      {:ok, info} = Malla.Service.get_service_info(TestService)

      assert info.id == TestService
      assert info.vsn == "1.0.0"
      assert info.admin_status == :active
      assert info.running_status == :running
      assert is_integer(info.last_status_time)
      assert info.last_status_reason == "init"
      assert is_pid(info.pid)
      assert info.node == node()
      assert is_list(info.callbacks)
      assert is_integer(info.hash)
    end

    test "service transitions to failed status on plugin failure", %{pid: _pid} do
      # Get plugin supervisor
      plug1_sup = Malla.Service.get_plugin_sup(TestService, TestPlugin1)

      # This test might not work if TestPlugin1 doesn't start children
      if is_pid(plug1_sup) do
        # Kill the plugin supervisor to simulate failure
        Process.exit(plug1_sup, :kill)
        Process.sleep(100)

        assert :failed == TestService.get_status()

        {:ok, info} = Malla.Service.get_service_info(TestService)
        assert info.running_status == :failed
        assert info.last_error != nil
      end
    end
  end

  describe "service_is_ready? callback" do
    test "is_ready? returns true when all plugins are ready" do
      # All flags default to true
      assert Malla.Service.is_ready?(TestService)
    end

    test "is_ready? returns false when service is not ready" do
      Malla.Service.put(TestService, :service_ready, false)
      refute Malla.Service.is_ready?(TestService)

      # Restore readiness
      Malla.Service.put(TestService, :service_ready, true)
      assert Malla.Service.is_ready?(TestService)
    end

    test "is_ready? returns false when plugin1 is not ready" do
      Malla.Service.put(TestService, :plugin1_ready, false)
      refute Malla.Service.is_ready?(TestService)

      # Restore readiness
      Malla.Service.put(TestService, :plugin1_ready, true)
      assert Malla.Service.is_ready?(TestService)
    end

    test "is_ready? returns false when plugin2 is not ready" do
      Malla.Service.put(TestService, :plugin2_ready, false)
      refute Malla.Service.is_ready?(TestService)

      # Restore readiness
      Malla.Service.put(TestService, :plugin2_ready, true)
      assert Malla.Service.is_ready?(TestService)
    end

    test "is_ready? returns false if any plugin in chain is not ready" do
      # Set multiple plugins as not ready
      Malla.Service.put(TestService, :service_ready, false)
      Malla.Service.put(TestService, :plugin1_ready, false)

      refute Malla.Service.is_ready?(TestService)
    end

    test "is_ready? returns false when service is not running" do
      :ok = TestService.set_admin_status(:pause, :test)
      Process.sleep(50)

      # Even if all flags are true, service is paused
      Malla.Service.put(TestService, :service_ready, true)
      Malla.Service.put(TestService, :plugin1_ready, true)
      Malla.Service.put(TestService, :plugin2_ready, true)

      refute Malla.Service.is_ready?(TestService)

      # Restart and verify readiness
      :ok = TestService.set_admin_status(:active, :test)
      Process.sleep(50)

      assert Malla.Service.is_ready?(TestService)
    end

    test "is_ready? callback chain stops at first false" do
      # Set plugin1 as not ready (plugin2 won't be reached)
      Malla.Service.put(TestService, :service_ready, true)
      Malla.Service.put(TestService, :plugin1_ready, false)
      Malla.Service.put(TestService, :plugin2_ready, true)

      refute Malla.Service.is_ready?(TestService)

      # Set plugin1 as ready, plugin2 as not ready
      Malla.Service.put(TestService, :plugin1_ready, true)
      Malla.Service.put(TestService, :plugin2_ready, false)

      refute Malla.Service.is_ready?(TestService)
    end
  end

  describe "service_drain callback" do
    test "drain returns true when all plugins are drained" do
      # All flags default to true
      assert Malla.Service.drain(TestService)
    end

    test "drain returns false when service is not drained" do
      Malla.Service.put(TestService, :service_drained, false)
      refute Malla.Service.drain(TestService)

      # Complete drain
      Malla.Service.put(TestService, :service_drained, true)
      assert Malla.Service.drain(TestService)
    end

    test "drain returns false when plugin1 is not drained" do
      Malla.Service.put(TestService, :plugin1_drained, false)
      refute Malla.Service.drain(TestService)

      # Complete drain
      Malla.Service.put(TestService, :plugin1_drained, true)
      assert Malla.Service.drain(TestService)
    end

    test "drain returns false when plugin2 is not drained" do
      Malla.Service.put(TestService, :plugin2_drained, false)
      refute Malla.Service.drain(TestService)

      # Complete drain
      Malla.Service.put(TestService, :plugin2_drained, true)
      assert Malla.Service.drain(TestService)
    end

    test "drain returns false if any plugin in chain is not drained" do
      # Set multiple plugins as not drained
      Malla.Service.put(TestService, :service_drained, false)
      Malla.Service.put(TestService, :plugin1_drained, false)

      refute Malla.Service.drain(TestService)

      # Drain service but not plugin1
      Malla.Service.put(TestService, :service_drained, true)
      refute Malla.Service.drain(TestService)

      # Drain plugin1
      Malla.Service.put(TestService, :plugin1_drained, true)
      assert Malla.Service.drain(TestService)
    end

    test "drain callback chain stops at first false" do
      # Set plugin1 as not drained (plugin2 won't be reached)
      Malla.Service.put(TestService, :service_drained, true)
      Malla.Service.put(TestService, :plugin1_drained, false)
      Malla.Service.put(TestService, :plugin2_drained, true)

      refute Malla.Service.drain(TestService)

      # Set plugin1 as drained, plugin2 as not drained
      Malla.Service.put(TestService, :plugin1_drained, true)
      Malla.Service.put(TestService, :plugin2_drained, false)

      refute Malla.Service.drain(TestService)
    end

    test "drain can be retried until all plugins complete" do
      # Simulate gradual drain completion
      Malla.Service.put(TestService, :service_drained, false)
      Malla.Service.put(TestService, :plugin1_drained, false)
      Malla.Service.put(TestService, :plugin2_drained, false)

      refute Malla.Service.drain(TestService)

      # Service completes drain
      Malla.Service.put(TestService, :service_drained, true)
      refute Malla.Service.drain(TestService)

      # Plugin1 completes drain
      Malla.Service.put(TestService, :plugin1_drained, true)
      refute Malla.Service.drain(TestService)

      # Plugin2 completes drain - now fully drained
      Malla.Service.put(TestService, :plugin2_drained, true)
      assert Malla.Service.drain(TestService)
    end
  end

  describe "is_live? utility" do
    test "is_live? returns true when service is in live states" do
      assert Malla.Service.is_live?(TestService)

      :ok = TestService.set_admin_status(:pause, :test)
      Process.sleep(50)
      assert Malla.Service.is_live?(TestService)

      :ok = TestService.set_admin_status(:inactive, :test)
      Process.sleep(50)
      assert Malla.Service.is_live?(TestService)
    end

    test "is_live? returns false for non-existent service" do
      refute Malla.Service.is_live?(NonExistentService)
    end

    test "is_live? returns false when service is in failed state", %{pid: _pid} do
      # Get plugin supervisor
      plug1_sup = Malla.Service.get_plugin_sup(TestService, TestPlugin1)

      # This test might not work if TestPlugin1 doesn't start children
      if is_pid(plug1_sup) do
        # Kill the plugin supervisor to simulate failure
        Process.exit(plug1_sup, :kill)
        Process.sleep(100)

        refute Malla.Service.is_live?(TestService)
      end
    end
  end

  describe "service paused start" do
    test "service starts in paused state when start_paused: true" do
      # Stop current service
      TestService.stop()
      Process.sleep(50)

      # Define service with start_paused
      defmodule PausedService do
        use Malla.Service,
          class: :test_paused,
          vsn: "1.0.0",
          paused: true
      end

      {:ok, _pid} = PausedService.start_link([])
      Process.sleep(50)

      assert :paused == PausedService.get_status()

      {:ok, info} = Malla.Service.get_service_info(PausedService)
      assert info.admin_status == :paused
      assert info.running_status == :paused

      # Activate the service
      :ok = PausedService.set_admin_status(:active, :activate)
      Process.sleep(50)

      assert :running == PausedService.get_status()

      PausedService.stop()
      Process.sleep(50)
    end
  end

  describe "status persistence" do
    test "status is cached in persistent_term for fast reads" do
      # Verify status can be read from persistent_term
      key = TestService.__service__(:status_key)
      assert :running == :persistent_term.get(key)

      # Change status and verify persistent_term is updated
      :ok = TestService.set_admin_status(:pause, :test)
      Process.sleep(50)

      assert :paused == :persistent_term.get(key)
    end

    test "multiple get_status calls are fast (no GenServer calls)" do
      # Measure time for multiple get_status calls
      start_time = System.monotonic_time(:microsecond)

      for _ <- 1..1000 do
        TestService.get_status()
      end

      end_time = System.monotonic_time(:microsecond)
      duration = end_time - start_time

      # 1000 calls should complete in well under 100ms (if using cached value)
      # Typically should be < 1ms for 1000 calls
      assert duration < 100_000, "get_status should be fast (cached)"
    end
  end

  describe "status error tracking" do
    test "last_error and last_error_time are tracked on failure", %{pid: _pid} do
      # Get plugin supervisor
      plug1_sup = Malla.Service.get_plugin_sup(TestService, TestPlugin1)

      # This test might not work if TestPlugin1 doesn't start children
      if is_pid(plug1_sup) do
        {:ok, info_before} = Malla.Service.get_service_info(TestService)
        assert info_before.last_error == nil
        assert info_before.last_error_time == 0

        # Kill the plugin supervisor to simulate failure
        Process.exit(plug1_sup, :kill)
        Process.sleep(100)

        {:ok, info_after} = Malla.Service.get_service_info(TestService)
        assert info_after.last_error != nil
        assert info_after.last_error_time > info_before.last_status_time
        assert info_after.running_status == :failed
      end
    end
  end
end
