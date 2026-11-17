## -------------------------------------------------------------------
##
## Copyright (c) 2026 Erlnets Technologies
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

defmodule Malla.Request do
  alias Malla.Request.ReqError

  @moduledoc """
  Client-side API for making structured requests to remote services.

  This module provides the `request/4` function and `req/2` macro for invoking
  operations on remote services using Malla's request protocol. The protocol
  adds distributed tracing, standardized responses, retry logic, and plugin
  interception on top of basic RPC.

  Usage of this mechanism is optional. You can always use basic Malla
  RPC using `Malla.remote/4` where this tools is based on.

  This tool requires the usage of `Malla.Status` and `Malla.Tracer`.
  When including plugin `Malla.Plugins.Request` in your service, it will
  include them too.


  ## Quick Example

  ```elixir
  defmodule APIService do
    use Malla.Service
    use Malla.Request  # Import req macro

    def get_user_info(user_id) do
      # Using macro syntax
      case req UserService.get_user(user_id) do
        {:ok, user} -> format_response(user)
        {:error, %Malla.Status{}} -> render_error()
      end
    end
  end
  ```

  ## Core Functions

  - `request/4` - Make a structured request to a remote service.
  - `request!/4` - Same as `request/4` but raises on error.
  - `req/1`, `req/2` - Macro versions for cleaner syntax.

  ## Request Flow

  1. Creates "request-out" span for tracing
  2. Calls `malla_request/3` callback (interceptable by plugins)
  3. Uses `Malla.remote/4` for RPC to target service
  4. Remote side creates "request-in" span
  5. Executes target function
  6. Normalizes response via `Malla.Status`
  7. Emits telemetry events

  ## Response Types

  Request handlers must return one of:

  - `:ok` - Success, no data
  - `:created` - Resource created, no data
  - `{:ok, data}` - Success with data (map or list)
  - `{:created, data}` - Resource created with data
  - `{:error, term}` - Error (normalized via `Malla.Status`)
  - `{:status, term}` - Custom status (normalized via `Malla.Status`)

  ## Options

  Both `request/4` and `req/2` accept options:

  - `:timeout` - Request timeout in milliseconds (default: 30_000)
  - `:direct` - Skip RPC, call locally (default: false)
  - `:retries` - Number of retries on failure
  - `:retry_delay` - Delay between retries in milliseconds
  - Plus any custom options for plugin use

  ## Examples

  ```elixir
  # Using req macro (recommended)
  use Malla.Request
  {:ok, user} = req UserService.get_user(123)
  {:created, post} = req BlogService.create_post(params)

  # Using explicit function
  Malla.Request.request(UserService, :get_user, [123])
  Malla.Request.request(UserService, :update_user, [123, params], timeout: 10_000)

  # With custom options
  req PaymentService.charge(order_id),
    timeout: 15_000,
    auth_token: token

  # Raising version
  {:ok, user} = request!(UserService, :get_user, [123])
  ```

  ## Telemetry

  Emits `[:malla, :request, :out]` events with:
  - Measurements: `:counter`, `:duration`
  - Metadata: `:target`, `:op`, `:result`, plus standard fields

  ## For Complete Documentation

  See the [Request Handling](guides/08-distribution/04-request-handling.md) guide
  for comprehensive documentation including:
  - Plugin-based interception (auth, rate limiting, validation)
  - Distributed tracing patterns
  - Error handling strategies
  - Testing approaches
  - Best practices

  ## See Also

  - `Malla.Plugins.Request` - Server-side request handling and plugin interface
  - `Malla.Node` - Lower-level RPC functions
  - `Malla.Status` - Response normalization
  """

  ## ===================================================================
  ## Macros
  ## ===================================================================

  defmacro __using__(_options) do
    quote do
      import Malla.Request,
        only: [req: 1, req: 2]
    end
  end

  @doc """
  Sends a request to a service, local or remote, written as a function call.

  `req MyApp.UserService.get_user(123)` expands to
  `Malla.Request.request(MyApp.UserService, :get_user, [123])`, and
  `req MyApp.UserService.get_user(123), timeout: 5000` passes the options as the
  fourth argument. See `request/4` for what it does and returns.

  The service must be written as a literal module name, in full: aliases are not
  expanded, and a variable does not match. Import the macro with
  `use Malla.Request`.
  """
  defmacro req(call)

  defmacro req({{:., _, [{:__aliases__, _, service_list}, fun]}, _, args}) do
    service_id = Module.concat(service_list)

    quote do
      Malla.Request.request(unquote(service_id), unquote(fun), unquote(args))
    end
  end

  @doc """
  Same as `req/1`, with options for `request/4`.
  """
  defmacro req(call, opts)

  defmacro req({{:., _, [{:__aliases__, _, service_list}, fun]}, _, args}, opts) do
    service_id = Module.concat(service_list)

    quote do
      Malla.Request.request(unquote(service_id), unquote(fun), unquote(args), unquote(opts))
    end
  end

  use Malla.Tracer

  @type op :: [:atom] | String.t()
  @type req_opt :: Malla.remote_opt() | {:direct, boolean}

  @doc """
  Sends a request to `fun` of `remote_service` inside a `"request-out"` span.

  The call goes through `Malla.remote/4` to the `malla_request/3` callback of
  the target service (see `Malla.Plugins.Request`), which runs `fun` with `args`
  in its own span. The base span is sent along so the trace continues on the
  other side.

  Options are those of `Malla.remote/4`, plus:

  * `:direct` - when `true`, calls `malla_request/3` of the target module in
    this node, without RPC.
  * `:service_id` - the calling service, when the process has none.

  The called function must answer `:ok`, `:created`, `{:ok, data}`,
  `{:created, data}` (with a map or list), or `{:error, status}` /
  `{:status, status}` with a `Malla.Status`. The result is always a two-element
  tuple: `:ok` and `:created` come back with an empty map, a transport error
  (such as `:malla_service_not_available` or a remote exception) becomes
  `{:error, %Malla.Status{}}` through `Malla.Status.public/2`, and any other
  answer becomes an `"internal_error"` status.
  """
  @spec request(Malla.id(), atom(), [any()], [req_opt()]) ::
          {:ok, map()} | {:created, map()} | {:error, map()} | {:status, map()}

  def request(remote_service, fun, args, opts \\ []) do
    srv = Malla.get_service_name(remote_service)
    service_id = Malla.get_service_id!(opts)
    start = System.monotonic_time()

    span "request-out", service_id: service_id, labels: [operation: fun] do
      # Arguments may carry secrets: logged through Malla.Util.redact_args/2
      info(
        "REQ for #{srv} '#{fun}' (#{inspect(Malla.Util.redact_args(fun, args))}) [#{inspect(opts)}]"
      )

      base_span = Malla.Tracer.get_base()
      # Pass the base span under both keys for backward compatibility: the
      # request-in side reads :base_span and falls back to :trace_base (the
      # older name) so plugins expecting either name keep working.
      opts = [{:trace_base, base_span}, {:base_span, base_span} | opts]
      args = [fun, args, opts]

      # if direct, we skip call to cb/2 at remote node and the
      # change of process leader

      result =
        if opts[:direct],
          do: apply(remote_service, :malla_request, args),
          else: Malla.remote(remote_service, :malla_request, args, opts)

      stop = System.monotonic_time()
      duration = System.convert_time_unit(stop - start, :native, :microsecond)

      {result, data} =
        case result do
          result when result in [:ok, :created] ->
            info("REQ result: '#{result}'")
            {result, %{}}

          {result, data} when result in [:ok, :created] and (is_map(data) or is_list(data)) ->
            info("REQ result: '#{result}'")
            debug("REQ response #{inspect(data)}")
            {result, data}

          {result, %Malla.Status{} = status} when result in [:status, :error] ->
            info("REQ result: '#{result}' (#{inspect(status)})")
            {result, status}

          {:error, reason} ->
            # Transport/normalization errors (e.g. service_not_available,
            # malla_rpc_error) reach the client as a bare reason: normalize it
            # into a public Status instead of crashing the caller.
            info("REQ 'error' (#{inspect(reason)})")
            {:error, Malla.Status.public(reason)}

          other ->
            # Reply outside the documented response contract (see "Response
            # Types"): turn it into a controlled internal error.
            notice("REQ invalid response: #{inspect(other)}")

            {:error,
             Malla.Status.public(%Malla.Status{
               status: "internal_error",
               info: "Invalid request response"
             })}
        end

      info("Duration is #{duration} usecs")

      Malla.metric(
        [:malla, :request, :out],
        %{counter: 1, duration: duration},
        %{target: srv, op: fun, result: result}
      )

      {result, data}
    end
  end

  @doc """
  Same as `request/4`, but raises `Malla.Request.ReqError` when the service is
  not available (`type: :service_not_available`) or the answer is an internal
  error (`type: :internal_error`). Other errors are returned.
  """

  @spec request!(Malla.id(), atom(), [any()], [req_opt()]) ::
          {:created, map()} | {:error, map()} | {:ok, map()} | {:status, map()}

  def request!(remote_service, op, args \\ [], opts \\ []) do
    case request(remote_service, op, args, opts) do
      {:error, %Malla.Status{status: "service_not_available"}} ->
        raise ReqError,
          type: :service_not_available,
          message: "REQUEST2: Service #{remote_service} not available calling #{inspect(op)}"

      {:error, %Malla.Status{status: "internal_error"}} ->
        raise Malla.Request.ReqError,
          type: :internal_error,
          message: "REQUEST2: Internal error calling #{remote_service} #{inspect(op)}"

      {result, data} ->
        {result, data}
    end
  end
end
