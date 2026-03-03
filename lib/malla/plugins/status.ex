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

defmodule Malla.Plugins.Status do
  @moduledoc """
  Plugin that provides status and error response management with extensible callbacks.

  This plugin works with `Malla.Status` to provide a complete status handling system.
  To use the system, include this plugin in your service's plugin list, and use
  `Malla.Status.status/2` or `Malla.Status.public/2` to convert statuses.

  This plugin provides default implementations for the the following callbacks:
  * `c:status/1`
  * `c:status_metadata/1`
  * `c:status_public/1`

  See `Malla.Status` for details.


  """

  use Malla.Plugin

  @optional_callbacks [
    status: 1,
    status_metadata: 1,
    status_public: 1
  ]

  @type span_id :: String.t() | [atom]

  @type status_return :: String.t() | [Malla.Status.status_opt()] | :cont

  ## ===================================================================
  ## Status Callbacks
  ## ===================================================================

  @doc """
  Converts a status term into a standardized status description.

  This callback receives any term representing a status or error and returns
  either a status description or `:cont` to delegate to the next plugin.

  ## Return Values

  The callback can return:

  1. **Keyword list** with status description options:
     - `:info` (string) - Human-readable message (becomes `info` field)
     - `:code` (integer) - Numeric code, typically HTTP status code
     - `:status` (string/atom) - Override the status identifier
     - `:data` (map/keyword) - Additional structured data
     - `:metadata` (map/keyword) - Service metadata

  2. **String** - Sets the `info` field directly (simple case)

  3. **`:cont`** - Skip this handler and try the next plugin

  ## Examples

      # Simple message
      defcb status(:not_found), do: [info: "Resource not found", code: 404]

      # With data
      defcb status({:invalid_field, field}),
        do: [info: "Invalid field", code: 400, data: [field: field]]

      # String return
      defcb status(:timeout), do: "Operation timed out"

      # Continue to next plugin
      defcb status(_), do: :cont

  Remember to always include a catch-all clause returning `:cont` to allow other plugins to handle unknown statuses.

  ## Implemented Status Codes

  This base implementation provides out-of-the-box a number of status patterns
  that are converted to statuses, but you can implement it too to support
  new ones or override the default ones.

  | Status Pattern | HTTP Code | Message |
  |---------------------|-----------|---------|
  | `:ok` | 200 | Success |
  | `{:ok_data, data}` | 200 | Success (with data) |
  | `:created` | 201 | Created |
  | `:deleted` | 200 | Deleted |
  | `:normal_termination` | 200 | Normal termination |
  | `:redirect` | 307 | Redirect |
  | `:bad_request` | 400 | Bad Request |
  | `:content_type_invalid` | 400 | Content type is invalid |
  | `{:field_invalid, field}` | 400 | Field is invalid |
  | `{:field_missing, field}` | 400 | Field is missing |
  | `{:field_unknown, field}` | 400 | Field is unknown |
  | `:file_too_large` | 400 | File too large |
  | `:invalid_parameters` | 400 | Invalid parameters |
  | `{:parameter_invalid, param}` | 400 | Invalid parameter |
  | `{:parameter_missing, param}` | 400 | Missing parameter |
  | `{:request_op_unknown, op}` | 400 | Request OP unknown |
  | `:request_body_invalid` | 400 | The request body is invalid |
  | `{:syntax_error, field}` | 400 | Syntax error |
  | `:token_invalid` | 400 | Token is invalid |
  | `:token_expired` | 400 | Token is expired |
  | `:unauthorized` | 401 | Unauthorized |
  | `:forbidden` | 403 | Forbidden |
  | `:not_found` | 404 | Not found |
  | `:resource_invalid` | 404 | Invalid resource |
  | `{:method_not_allowed, method}` | 405 | Method not allowed |
  | `:verb_not_allowed` | 405 | Verb is not allowed |
  | `:timeout` | 408 | Timeout |
  | `:conflict` | 409 | Conflict |
  | `:not_allowed` | 409 | Not allowed |
  | `:service_not_found` | 409 | Service not found |
  | `{:service_not_found, service}` | 409 | Service not found (specific) |
  | `:gone` | 410 | Gone |
  | `:unprocessable` | 422 | Unprocessable |
  | `:internal_error` | 500 | Internal error |
  | `{:internal_error, ref}` | 500 | Internal error (with ref) |
  | `:service_not_available` | 500 | RPC service unavailable |
  | `:not_implemented` | 501 | Not implemented |
  | `{:service_not_available, service}` | 503 | Service not available (specific) |

  """
  @callback status(Malla.Status.user_status()) :: status_return()

  defcb status(:ok), do: [info: "Success", code: 200]
  defcb status({:ok_data, data}), do: [info: "Success", code: 200, data: data]
  # defcb status({:ok, data}), do: [info: "Success", code: 200, data: data]
  defcb status(:created), do: [info: "Created", code: 201]
  defcb status(:deleted), do: [info: "Deleted", code: 200]
  defcb status(:bad_request), do: [info: "Bad Request", code: 400]
  defcb status(:conflict), do: [info: "Conflict", code: 409]
  defcb status(:content_type_invalid), do: [info: "Content type is invalid", code: 400]

  defcb status({:malla_rpc_error, {_term, text}}), do: [info: text, code: 500]

  defcb status({:field_invalid, field}),
    do: [info: "Field '#{field}' is invalid", code: 400, data: [field: field]]

  defcb status({:field_missing, field}),
    do: [info: "Field '#{field}' is missing", code: 400, data: [field: field]]

  defcb status({:field_unknown, field}),
    do: [info: "Field '#{field}' is unknown", code: 400, data: [field: field]]

  defcb status(:file_too_large), do: [info: "File too large", code: 400]
  defcb status(:forbidden), do: [info: "Forbidden", code: 403]
  defcb status(:gone), do: [info: "Gone", code: 410]

  defcb status(:internal_error),
    do: [info: "Internal error", code: 500, data: [node: to_string(node())]]

  #
  defcb status({:internal_error, ref}),
    do: [
      info: "Internal error: #{inspect(ref)}",
      code: 500,
      data: [ref: ref, node: to_string(node())]
    ]

  defcb status(:invalid_parameters), do: [info: "Invalid parameters", code: 400]

  defcb status({:malla_exception, exception}),
    do: [info: "MallaSpans EXCEPTION: #{inspect(exception)}", code: 500]

  defcb status({:malla_exit, exit}),
    do: [info: "MallaSpans EXIT: #{inspect(exit)}", code: 500]

  defcb status(:service_not_available), do: [info: "RPC service unavailable", code: 500]

  defcb status({:method_not_allowed, method}),
    do: [info: "Method not allowed: '#{method}'", code: 405]

  defcb status(:not_allowed), do: [info: "Not allowed", code: 409]
  defcb status(:normal_termination), do: [info: "Normal termination", code: 200]
  defcb status(:not_found), do: [info: "Not found", code: 404]
  defcb status(:not_implemented), do: [info: "Not implemented", code: 501]

  defcb status({:parameter_invalid, param}),
    do: [info: "Invalid parameter '#{param}'", code: 400, data: [parameter: param]]

  defcb status({:parameter_missing, param}),
    do: [info: "Missing parameter '#{param}'", code: 400, data: [parameter: param]]

  defcb status(:redirect), do: [info: "Redirect", code: 307]

  defcb status({:request_op_unknown, op}),
    do: [info: "Request OP unknown: #{Malla.Util.join_dots(op)}", code: 400]

  defcb status(:request_body_invalid), do: [info: "The request body is invalid", code: 400]
  defcb status(:resource_invalid), do: [info: "Invalid resource", code: 404]

  defcb status({:resource_invalid, res}),
    do: [info: "Invalid resource '#{res}'", code: 200, data: [resource: res]]

  defcb status({:resource_invalid, group, res}),
    do: [
      info: "Invalid resource '#{res}' (#{group}",
      code: 200,
      data: [resource: res, group: group]
    ]

  defcb status(:service_not_found), do: [info: "Service not found", code: 409]

  defcb status({:service_not_found, service}),
    do: [info: "Service '#{service}' not found", code: 409]

  defcb status({:service_not_available, service}) do
    service = Malla.get_service_name(service)
    [info: "Service '#{service}' not available", code: 503, data: [service: service]]
  end

  defcb status({:syntax_error, field}),
    do: [info: "Syntax error: '#{field}'", code: 400, data: [field: field]]

  defcb status({:tls_alert, error}), do: "Error TLS: #{error}"
  defcb status(:timeout), do: [info: "Timeout", code: 408]

  defcb status(:token_invalid), do: [info: "Token is invalid", code: 400]
  defcb status(:token_expired), do: [info: "Token is expired", code: 400]

  defcb status(:unauthorized), do: [info: "Unauthorized", code: 401]
  defcb status(:unprocessable), do: [info: "Unprocessable", code: 422]
  defcb status(:verb_not_allowed), do: [info: "Verb is not allowed", code: 405]
  defcb status(_), do: :continue

  @doc """
  Adds or modifies metadata in a generated status structure.

  This callback is invoked after a status has been fully constructed, allowing
  plugins to inject additional metadata based on the service context or status content.

  ## Examples

      # Conditional metadata based on status
      defcb status_metadata(%{status: "internal_error"} = status) do
        metadata = Map.put(status.metadata, "support_contact", "support@example.com")
        %{status | metadata: metadata}
      end

      # Add service information to metadata
      defcb status_metadata(status) do
        metadata = Map.merge(status.metadata, %{
          "service" => "MyService",
          "version" => "1.0.0",
          "node" => to_string(node())
        })
        %{status | metadata: metadata}
      end

      defcb status_metadata(status), do: status

  ## Use Cases

  - Adding service identification (name, version, node)
  - Including timestamps or request IDs
  - Adding environment information (production, staging, etc.)
  - Injecting support contact information for errors
  - Adding trace IDs for distributed tracing
  """
  @callback status_metadata(Malla.Status.t()) :: Malla.Status.t()
  defcb status_metadata(status), do: status

  @doc """
  Handles unmatched statuses when using `Malla.Status.public/1`.

  This callback is invoked when `public/2` encounters a status that has no
  matching `status/1` callback implementation. It allows services to customize
  how internal errors are exposed to external consumers.

  By default, this callback:
  1. Generates a unique reference number
  2. Logs a warning with the full status details and reference
  3. Returns a sanitized status struct with "internal_error" and the reference

  ## Examples

      # Default behavior (log and hide details)
      defcb status_public(user_status) do
        ref = rem(:erlang.phash2(:erlang.make_ref()), 10000)
        Logger.warning("Internal error: \#{inspect(ref)}: \#{inspect(user_status)} (\#{srv_id})")
        %Malla.Status{
          status: "internal_error",
          info: "Internal reference \#{ref}",
          code: 500
        }
      end

      defcb status_public(user_status) do
        # Fall back to default for everything else
        :cont
      end

  ## Use Cases

  - Customizing which errors are safe to expose externally
  - Adding custom logging or monitoring for unhandled statuses
  - Providing different sanitization strategies per service
  - Routing certain error patterns to external error tracking services
  """
  @callback status_public(Malla.Status.user_status()) :: Malla.Status.t() | :cont

  defcb status_public(user_status) do
    require Logger
    ref = rem(:erlang.phash2(:erlang.make_ref()), 10000)
    msg = "#{inspect(ref)}: #{inspect(user_status)} (#{Malla.get_service_id!()})"
    Logger.warning("Malla reference " <> msg)

    %Malla.Status{
      status: "internal_error",
      info: "Internal reference " <> Malla.Status.string(ref),
      code: 500
    }
  end
end
