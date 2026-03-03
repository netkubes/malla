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

defmodule Malla.Plugins.Request do
  @moduledoc """
  Server-side plugin for handling incoming requests via the Malla request protocol.



  This plugin defines the `c:malla_request/3` callback that is invoked when a
  remote service makes a request using `Malla.Request.request/4`. It provides
  the default implementation that creates tracing spans, checks service status,
  executes the target function, and normalizes responses.

  Plugins can override this callback to add cross-cutting concerns like
  authentication, rate limiting, validation, and logging.

  ## Callback

  - `c:malla_request/3` - Handle incoming request, return standardized response

  ## Default Implementation

  The default `malla_request/3`:

  1. Checks if service is running (returns error if not)
  2. Creates "request-in" span (child of caller's "request-out" span)
  3. Calls the target function with provided arguments
  4. Normalizes response via `Malla.Status.public/1`
  5. Emits `[:malla, :request, :in]` telemetry event
  6. Returns standardized response

  ## Plugin Interception

  Override `malla_request/3` to intercept requests:

  ```elixir
  defmodule AuthPlugin do
    use Malla.Plugin

    defcb malla_request(fun, args, opts) do
      case verify_auth_token(opts[:auth_token]) do
        {:ok, user_id} ->
          # Add user_id to opts and continue
          {:cont, [fun, args, Keyword.put(opts, :user_id, user_id)]}

        {:error, _reason} ->
          {:error, :unauthorized}
      end
    end
  end
  ```

  ## Response Protocol

  Functions called via the request protocol must return:

  - `:ok` | `:created` - Success without data
  - `{:ok | :created, map | list}` - Success with data
  - `{:error, term}` - Error (normalized via `Malla.Status`)
  - `{:status, term}` - Custom status (normalized via `Malla.Status`)

  ## Callback Chain

  When a request arrives:

  ```
  malla_request/3 call
  ├─ ValidationPlugin.malla_request/3
  ├─ AuthPlugin.malla_request/3
  ├─ RateLimitPlugin.malla_request/3
  └─ Default implementation
     ├─ Check service status
     ├─ Create "request-in" span
     ├─ Call target function
     ├─ Normalize response
     └─ Emit telemetry
  ```

  ## Telemetry

  Emits `[:malla, :request, :in]` events with:
  - Measurements: `:counter`, `:duration`
  - Metadata: `:op`, `:result`, plus standard fields

  ## For Complete Documentation

  See the [Request Handling](guides/08-distribution/04-request-handling.md) guide
  for comprehensive examples including:
  - Authentication plugins
  - Rate limiting plugins
  - Validation plugins
  - Composing multiple plugins
  - Conditional plugin logic
  - Testing strategies

  ## See Also

  - `Malla.Request` - Client-side request API
  - `Malla.Plugin` - Plugin development guide
  - `Malla.Status` - Response normalization
  """

  use Malla.Plugin, plugin_deps: [Malla.Plugins.Tracer, Malla.Plugins.Status]
  use Malla.Tracer

  @optional_callbacks [
    malla_request: 3
  ]

  ## ===================================================================
  ## Request Callbacks
  ## ===================================================================

  # @doc """
  # This callback will be called when a incoming request reaches
  # your service (see `Malla.Request`).

  # You must implement it for your supported requests.
  # Default implementation here shows an error message and returns
  # `{:error, :request_not_implemented}`
  # """
  # @callback request([:atom] | String.t(), map, keyword) ::
  #             :ok | :created | {:ok | :created, map} | {:error | :status, term}

  # defcb request(op, _params, _opts) do
  #   Logger.warning("Request #{inspect(op)} not implemented")
  #   {:error, :request_not_implemented}
  # end

  @doc """
  Default implementation for incoming requests.

  * First it checks if service is running, returning `{:error, :malla_service_not_available}` in that case
  * It tries to use base span_id in option `base_span_id`
  """
  @callback malla_request(atom, list, keyword) ::
              {:ok | :created, map}
              | {:error | :status, Malla.Status.t()}
              | {:error, :malla_service_not_available}
              | {:error, {:malla_rpc_error, any}}

  defcb malla_request(fun, args, opts) do
    srv_id = Malla.get_service_id!()

    case srv_id.get_status() do
      :running ->
        service = Malla.get_service_name(srv_id)
        start = System.monotonic_time()

        base =
          case Keyword.get(opts, :base_span) do
            nil -> Keyword.fetch!(opts, :trace_base)
            trace_base -> trace_base
          end

        span "request-in",
          base: base,
          labels: [operation: fun] do
          info("REQ Incoming #{service}: '#{fun}' (#{inspect(args)})")

          {result, data} =
            case apply(srv_id, fun, args) do
              result when result in [:ok, :created] ->
                info("REQ result: '#{result}'")
                {result, %{}}

              {result, data} when result in [:ok, :created] and (is_map(data) or is_list(data)) ->
                info("REQ result: '#{result}'")
                debug("REQ response #{inspect(data)}")
                {result, data}

              {:status, status} ->
                info("REQ 'status' (#{inspect(status)})")
                {:status, Malla.Status.public(status)}

              {:error, error} ->
                info("REQ 'error' (#{inspect(error)})")
                error(error)
                {:error, Malla.Status.public(error)}
            end

          stop = System.monotonic_time()
          duration = System.convert_time_unit(stop - start, :native, :microsecond)
          info("Duration is #{duration} usecs")

          Malla.metric(
            [:malla, :request, :in],
            %{counter: 1, duration: duration},
            %{op: fun, result: result}
          )

          {result, data}
        end

      status ->
        notice("Rejecting request for #{inspect(srv_id)} on #{status}")
        {:error, :malla_service_not_available}
    end
  end
end
