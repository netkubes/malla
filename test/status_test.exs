defmodule Malla.StatusTest do
  @moduledoc false
  # Test suite for Malla.Status core module and Malla.Plugins.Status plugin.

  # Tests cover:
  # - Basic status conversion with `status/2`
  # - Public/external status conversion with `public/2`
  # - Custom status callback implementations
  # - Status metadata injection
  # - Built-in status patterns from the plugin
  # - Edge cases and error handling

  use ExUnit.Case, async: false
  alias Malla.Status

  # Import test service from support file
  alias StatusTestService

  setup do
    # Clean up any running services from previous tests
    pid = Process.whereis(StatusTestService)

    if pid && Process.alive?(pid) do
      try do
        StatusTestService.stop()
        Process.sleep(50)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  describe "basic status conversion with status/2" do
    test "basic status" do
      {:ok, _pid} = StatusTestService.start_link([])

      status = Status.status(StatusTestService, :ok)
      assert %Status{} = status
      assert status.status == "ok"
      assert status.code == 200
      assert status.info == "Success"

      status = Status.status(StatusTestService, "custom_status")
      assert %Status{} = status
      assert status.status == "custom_status"
      assert status.code == 0
      assert status.info == "custom_status"

      status = Status.status(StatusTestService, {:error, "Something went wrong"})
      assert %Status{} = status
      assert status.status == "error"
      assert status.info == "Something went wrong"
      assert status.code == 0

      status = Status.status(StatusTestService, {404, :not_found, "Resource missing"})
      assert %Status{} = status
      assert status.status == "not_found"
      assert status.info == "Resource missing"
      assert status.code == 404

      status = Status.status(StatusTestService, {{:error, :details}, "Failed"})
      assert %Status{} = status
      assert status.status == "error"

      original = %Status{status: "test", info: "Test", code: 123}
      status = Status.status(StatusTestService, original)

      # The status struct is returned but metadata is added via status_metadata callback
      assert status.status == original.status
      assert status.info == original.info
      assert status.code == original.code
      assert status.data == original.data
      # Metadata gets added by the callback
      assert status.metadata["service_name"] == "StatusTestService"

      status = Status.status(StatusTestService, %{unknown: :type})
      assert %Status{} = status
      assert status.status == "unknown"
      # String representation may use either %{} or #{}
      assert status.info =~ "unknown" and status.info =~ "type"
    end
  end

  describe "public status conversion with public/2" do
    test "converts standard statuses same as status/2" do
      {:ok, _pid} = StatusTestService.start_link([])

      status = Status.public(StatusTestService, :ok)
      assert %Status{} = status
      assert status.status == "ok"
      assert status.code == 200

      status = Status.public(StatusTestService, {:badarg, %{internal: :data}})
      assert %Status{} = status
      assert status.status == "internal_error"
      assert String.contains?(status.info, "Internal reference")

      status = Status.public(StatusTestService, {:badarith, "details"})
      assert %Status{} = status
      assert status.status == "internal_error"
      assert String.contains?(status.info, "Internal reference")

      status = Status.public(StatusTestService, {:function_clause, "details"})
      assert %Status{} = status
      assert status.status == "internal_error"

      status = Status.public(StatusTestService, {{:badmatch, :value}, "context"})
      assert %Status{} = status
      assert status.status == "internal_error"

      status = Status.public(StatusTestService, {{:case_clause, :value}, "context"})
      assert %Status{} = status
      assert status.status == "internal_error"

      status = Status.public(StatusTestService, {:error, "User-facing message"})
      assert %Status{} = status
      # With no callback match, public/2 treats it as internal error
      assert status.status == "internal_error"
      assert String.contains?(status.info, "Internal reference")

      status = Status.public(StatusTestService, {:timeout, %{data: :internal}})
      assert %Status{} = status
      # With no callback match, public/2 treats it as internal error
      assert status.status == "internal_error"
      assert String.contains?(status.info, "Internal reference")
    end

    test "calls status_public callback for unmatched statuses" do
      {:ok, _pid} = StatusTestService.start_link([])

      # Test that status_public callback is invoked for unmatched statuses
      status = Status.public(StatusTestService, {:unknown_internal, %{secret: :data}})
      assert %Status{} = status
      assert status.status == "internal_error"
      assert String.contains?(status.info, "Internal reference")

      # Test that custom status_public implementation can expose specific patterns
      status = Status.public(StatusTestService, {:safe_error, "This is safe to expose"})
      assert %Status{} = status
      assert status.status == "safe_error"
      assert status.info == "This is safe to expose"
      assert status.code == 400
    end

    test "status_public callback receives correct arguments" do
      {:ok, _pid} = StatusTestService.start_link([])

      # Verify the callback is called with user_status and srv_id
      user_status = {:safe_error, "Test message"}
      status = Status.public(StatusTestService, user_status)

      assert status.status == "safe_error"
      assert status.info == "Test message"
    end

    test "status_public default behavior logs warning" do
      {:ok, _pid} = StatusTestService.start_link([])

      # Capture log output
      import ExUnit.CaptureLog

      # Temporarily enable warning level for this test
      old_level = Logger.level()
      Logger.configure(level: :warning)

      log =
        capture_log(fn ->
          status = Status.public(StatusTestService, {:unknown_error, "internal details"})
          assert status.status == "internal_error"
          assert String.contains?(status.info, "Internal reference")
        end)

      # Restore original log level
      Logger.configure(level: old_level)

      # Verify that a warning was logged
      assert log =~ "Malla reference"
      assert log =~ "unknown_error"
      assert log =~ "StatusTestService"
    end
  end

  describe "built-in status patterns from plugin" do
    test "standard handles" do
      {:ok, _pid} = StatusTestService.start_link([])

      status = Status.status(StatusTestService, :created)
      assert status.status == "created"
      assert status.info == "Created"
      assert status.code == 201

      status = Status.status(StatusTestService, :deleted)
      assert status.status == "deleted"
      assert status.info == "Deleted"
      assert status.code == 200

      status = Status.status(StatusTestService, :bad_request)
      assert status.status == "bad_request"
      assert status.info == "Bad Request"
      assert status.code == 400

      status = Status.status(StatusTestService, :unauthorized)
      assert status.status == "unauthorized"
      assert status.info == "Unauthorized"
      assert status.code == 401

      status = Status.status(StatusTestService, :forbidden)
      assert status.status == "forbidden"
      assert status.info == "Forbidden"
      assert status.code == 403

      status = Status.status(StatusTestService, :not_found)
      assert status.status == "not_found"
      assert status.info == "Not found"
      assert status.code == 404

      status = Status.status(StatusTestService, :timeout)
      assert status.status == "timeout"
      assert status.info == "Timeout"
      assert status.code == 408

      status = Status.status(StatusTestService, :conflict)
      assert status.status == "conflict"
      assert status.info == "Conflict"
      assert status.code == 409

      status = Status.status(StatusTestService, :internal_error)
      assert status.status == "internal_error"
      assert status.info == "Internal error"
      assert status.code == 500
      assert status.data["node"] == to_string(node())

      status = Status.status(StatusTestService, {:internal_error, "ref123"})
      assert status.status == "internal_error"
      assert String.contains?(status.info, "ref123")
      assert status.code == 500

      status = Status.status(StatusTestService, :not_implemented)
      assert status.status == "not_implemented"
      assert status.info == "Not implemented"
      assert status.code == 501
    end
  end

  describe "parameterized status patterns" do
    test "parameterized patterns" do
      {:ok, _pid} = StatusTestService.start_link([])

      status = Status.status(StatusTestService, {:field_invalid, "email"})
      assert status.status == "field_invalid"
      assert status.info == "Field 'email' is invalid"
      assert status.code == 400
      assert status.data["field"] == "email"

      status = Status.status(StatusTestService, {:field_missing, "password"})
      assert status.status == "field_missing"
      assert status.info == "Field 'password' is missing"
      assert status.code == 400
      assert status.data["field"] == "password"

      status = Status.status(StatusTestService, {:field_unknown, "extra_field"})
      assert status.status == "field_unknown"
      assert status.info == "Field 'extra_field' is unknown"
      assert status.code == 400
      assert status.data["field"] == "extra_field"

      status = Status.status(StatusTestService, {:parameter_invalid, "limit"})
      assert status.status == "parameter_invalid"
      assert status.info == "Invalid parameter 'limit'"
      assert status.code == 400
      assert status.data["parameter"] == "limit"

      status = Status.status(StatusTestService, {:parameter_missing, "api_key"})
      assert status.status == "parameter_missing"
      assert status.info == "Missing parameter 'api_key'"
      assert status.code == 400
      assert status.data["parameter"] == "api_key"

      status = Status.status(StatusTestService, {:service_not_found, "PaymentService"})
      assert status.status == "service_not_found"
      assert String.contains?(status.info, "PaymentService")
      assert status.code == 409

      status = Status.status(StatusTestService, {:method_not_allowed, "DELETE"})
      assert status.status == "method_not_allowed"
      assert String.contains?(status.info, "DELETE")
      assert status.code == 405
    end
  end

  describe "custom status callbacks" do
    test "service can override built-in statuses" do
      {:ok, _pid} = StatusTestService.start_link([])
      # StatusTestService overrides :not_found with custom message
      status = Status.status(StatusTestService, :custom_not_found)
      assert status.status == "custom_not_found"
      assert status.info == "Custom: Resource not found"
      assert status.code == 404

      status = Status.status(StatusTestService, :business_rule_violation)
      assert status.status == "business_rule_violation"
      assert status.info == "Business rule violated"
      assert status.code == 422

      status = Status.status(StatusTestService, {:rate_limit_exceeded, 100})
      assert status.status == "rate_limit_exceeded"
      assert status.info == "Rate limit exceeded"
      assert status.code == 429
      assert status.data["limit"] == "100"

      status = Status.status(StatusTestService, :simple_error)
      assert status.status == "simple_error"
      assert status.info == "A simple error occurred"
      assert status.code == 0

      status = Status.status(StatusTestService, :special_case)
      assert status.status == "special_error"
      assert status.info == "This is a special case"
      assert status.code == 400
    end
  end

  describe "status metadata injection" do
    test "status metadata injection" do
      {:ok, _pid} = StatusTestService.start_link([])

      status = Status.status(StatusTestService, :ok)
      assert status.metadata["service_name"] == "StatusTestService"
      assert status.metadata["version"] == "1.0.0"
      assert Map.has_key?(status.metadata, "timestamp")

      status = Status.status(StatusTestService, :not_found)
      assert status.metadata["service_name"] == "StatusTestService"
      assert status.metadata["version"] == "1.0.0"

      status = Status.status(StatusTestService, :business_rule_violation)
      assert status.metadata["service_name"] == "StatusTestService"

      status = Status.status(StatusTestService, :internal_error)
      # StatusTestService adds support_contact for error statuses
      assert Map.has_key?(status.metadata, "support_contact")
    end
  end

  describe "status with data" do
    test "status with data" do
      {:ok, _pid} = StatusTestService.start_link([])

      status = Status.status(StatusTestService, {:ok_data, %{user_id: 123, name: "John"}})
      assert status.status == "ok_data"
      assert status.code == 200
      assert status.data["user_id"] == "123"
      assert status.data["name"] == "John"

      status = Status.status(StatusTestService, {:ok_data, %{count: 42, status: :active}})
      assert status.data["count"] == "42"
      assert status.data["status"] == "active"
    end
  end

  describe "utility functions" do
    test "utilities" do
      assert Status.string(:test) == "test"
      assert Status.string("test") == "test"
      assert Status.string(123) == "123"

      result = Status.string(%{key: :value})
      assert is_binary(result)
      assert String.contains?(result, "key")
    end

    test "converts status to human-readable string" do
      status = %Status{status: "ok", info: "Success", code: 200}
      result = to_string(status)
      assert result == "<STATUS ok (200): Success>"

      status = %Status{status: "test", info: "", code: 0}
      result = to_string(status)
      assert result == "<STATUS test (0): >"
    end

    test "uses service ID from process dictionary" do
      # Simulate being inside service process
      Malla.put_service_id(StatusTestService)

      status = Status.public(:ok)
      assert %Status{} = status
      assert status.status == "ok"
      assert status.code == 200

      original = %Status{status: "test", info: "Test", code: 123}
      status = Status.public(original)
      assert status == original
    end
  end

  describe "edge cases and error handling" do
    test "edge cases" do
      {:ok, _pid} = StatusTestService.start_link([])

      status = Status.status(StatusTestService, {})
      assert %Status{} = status
      assert status.status == "unknown"
    end

    test "handles list as status" do
      {:ok, _pid} = StatusTestService.start_link([])
      status = Status.status(StatusTestService, [:not, :a, :status])

      assert %Status{} = status
      assert status.status == "unknown"
    end

    test "handles integer as status" do
      {:ok, _pid} = StatusTestService.start_link([])
      status = Status.status(StatusTestService, 404)

      assert %Status{} = status
      assert status.status == "unknown"
      assert status.info == "404"
    end

    test "handles nil as status" do
      {:ok, _pid} = StatusTestService.start_link([])
      status = Status.status(StatusTestService, nil)

      assert %Status{} = status
      # nil gets converted to empty string by Status.string/1
      assert status.status == ""
    end

    test "public/2 handles various tuple sizes" do
      {:ok, _pid} = StatusTestService.start_link([])
      status = Status.public(StatusTestService, {:a, :b, :c, :d})

      assert %Status{} = status

      # Since :a is not a known status and there's no callback match, public/2 logs it and returns internal_error
      assert status.status == "internal_error"
      assert String.contains?(status.info, "Internal reference")
    end
  end
end
