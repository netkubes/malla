defmodule StatusTestService do
  @moduledoc false

  # Test service for Malla.Status testing.

  # Demonstrates:
  # - Custom status callback implementations
  # - Overriding built-in status patterns
  # - Status metadata injection
  # - Various status return formats

  use Malla.Service,
    plugins: [Malla.Plugins.Status],
    global: false

  ## ===================================================================
  ## Custom Status Callbacks
  ## ===================================================================

  # Custom status implementation that overrides :not_found
  defcb status(:custom_not_found),
    do: [info: "Custom: Resource not found", code: 404]

  # New status pattern for business rule violations
  defcb status(:business_rule_violation),
    do: [info: "Business rule violated", code: 422]

  # Parameterized status with rate limiting
  defcb status({:rate_limit_exceeded, limit}),
    do: [info: "Rate limit exceeded", code: 429, data: [limit: limit]]

  # Simple string return format
  defcb status(:simple_error),
    do: "A simple error occurred"

  # Status with overridden status field
  defcb status(:special_case),
    do: [status: "special_error", info: "This is a special case", code: 400]

  # Handle three-element tuple with {code, status, info} pattern
  defcb status({code, status, info}) when is_integer(code),
    do: [status: to_string(status), info: to_string(info), code: code]

  # Continue to next plugin for unknown statuses
  defcb status(_), do: :cont

  ## ===================================================================
  ## Status Public Callback
  ## ===================================================================

  # Custom handling for certain unmatched statuses in public/2
  # This allows exposing specific error patterns to external consumers
  defcb status_public({:safe_error, message}) do
    # This error pattern is safe to expose
    %Malla.Status{status: "safe_error", info: message, code: 400}
  end

  # Fall back to default behavior for all other unmatched statuses
  defcb status_public(_user_status), do: :cont

  ## ===================================================================
  ## Status Metadata
  ## ===================================================================

  # Adds custom metadata to all status responses
  defcb status_metadata(status) do
    # Base metadata for all statuses
    base_metadata = %{
      "service_name" => "StatusTestService",
      "version" => "1.0.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Add conditional metadata based on status type
    conditional_metadata =
      case status.status do
        "internal_error" ->
          %{"support_contact" => "support@example.com"}

        _ ->
          %{}
      end

    metadata = Map.merge(status.metadata, base_metadata)
    metadata = Map.merge(metadata, conditional_metadata)

    %{status | metadata: metadata}
  end
end
