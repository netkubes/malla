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

defmodule Malla.Status do
  @moduledoc """
  Provides core utilities for standardizing status and error responses.

  This module defines the `t:Malla.Status.t/0` struct and the foundational logic for
  converting internal application responses into this standardized structure. It works
  in tandem with the `Malla.Plugins.Status` plugin, which provides an extensible
  callback-based system for defining status patterns.

  For a complete guide on how to use the status system, including defining custom
  statuses, see the **[Status and Error Handling guide](guides/09-observability/02-status-handling.md)**.
  """

  alias __MODULE__

  @type t :: %Status{
          status: String.t(),
          info: String.t(),
          code: integer,
          data: map,
          metadata: map
        }

  @type user_status :: any | t

  defstruct status: "", info: "", code: 0, data: %{}, metadata: %{}

  @typedoc """
  Options for describing a status in callback implementations.

  Available options:
  - `:info` - Human-readable message (becomes the `info` field)
  - `:code` - Numeric code, typically HTTP status code
  - `:status` - Override the status identifier string
  - `:data` - Additional structured data (map or keyword list)
  - `:metadata` - Service metadata (map or keyword list)

  If no `:status` is provided, we try to find one based on original _user_status_:
  - if it was an _atom_ or _binary_, that is the `:status`
  - if it is a tuple, we check if the first element is an _atom_ or _binary_, even if nested
  - otherwise we set it to "unknown"
  """
  @type status_opt ::
          {:info, term()}
          | {:code, integer()}
          | {:status, term()}
          | {:data, list() | map()}
          | {:metadata, list() | map()}

  ## ===================================================================
  ## Public
  ## ===================================================================

  @doc """
  Expands a service response into a `t:t/0` structure for public consumption.

  This is a convenience wrapper around `status/2` that uses the service ID
  from the current process dictionary using `Malla.get_service_id!/0`.
  """
  @spec status(user_status) :: t
  def status(%Malla.Status{} = status), do: status
  def status(user_status), do: public(Malla.get_service_id!(), user_status)

  @doc """
  Expands a service response into a `t:t/0` structure.

  This function converts internal service responses (statuses and errors) into
  a standardized Status struct for external consumption.

  ## Conversion Process

  1. First we call callback `c:Malla.Plugins.Status.status/1` that must be defined if we included
     plugin `Malla.Plugins.Status` in the indicated service. If we (or our plugins) implemented
     this function, it will be called first, using, as last resort, the base implementation.

  2. Callback function can return:
     - an string: we will consider this as `:info` field. We will try to extract `:status` field from
       the _user_status_ (if it is an _atom_ or _string_ or first element of a _tuple_) or it will set to "unknown".
     - a list of options (`t:status_opt/0`). Struct will be populated according to this.
       If no `:status` is provided, we follow same rules as above.

  3. If no callback implementation matches this _user_status_:
     - we try to guess `:status` with same rules as above or it will be set to "unknown".
     - we include `:info` as a string representation of the whole _user_status_, unless it is
       a _two-elements tuple_, in that case we use only the second part of it.

  4. Then `:metadata` may be added calling `c:Malla.Plugins.Status.status_metadata/1`. If it was provided by
     the `c:Malla.Plugins.Status.status/1` callback, it will be merged.

  """
  @spec status(Malla.id(), user_status) :: t

  def status(srv_id, %Status{} = t), do: add_metadata(t, srv_id)

  def status(srv_id, user_status) do
    case call_cb(srv_id, user_status) do
      {true, t} ->
        t

      false ->
        case user_status do
          {status, info} ->
            %Status{status: make_status(status), info: string(info)}

          _ ->
            %Status{status: make_status(user_status), info: string(user_status)}
        end
    end
    |> add_metadata(srv_id)
  end

  @doc """
  Expands a service response into a `t:t/0` structure for public consumption.

  This is a convenience wrapper around `public/2` that uses the service ID
  from the current process dictionary using `Malla.get_service_id!/0`.
  """
  @spec public(user_status) :: t
  def public(%Malla.Status{} = status), do: status

  def public(status), do: public(Malla.get_service_id!(), status)

  @doc """
  Expands a service response into a `t:t/0` structure for public/external use.

  Similar to `status/2`, but provides additional safety to avoid exposing internal
  errors to external systems. If we find no result from the `c:Malla.Plugins.Status.status/1`
  callback, the `c:Malla.Plugins.Status.status_public/1` callback is invoked to handle
  the unmatched status.

  By default, `status_public/2` will:
  - Log a warning with the full _user_status_ and a unique reference
  - Return a sanitized status with `:status` set to "internal_error" and `:info` indicating the reference

  Services can override `status_public/2` to customize this behavior, such as exposing
  certain error patterns or implementing custom logging strategies.

  ## Examples

      iex> Malla.Status.public(MyService, :ok)
      %Malla.Status{status: "ok"}

      iex> Malla.Status.public(MyService, {:badarg, %{some: :internal_data}})
      %Malla.Status{status: "internal_error", info: "Internal reference 1234"}
  """
  @spec public(Malla.id(), user_status) :: t

  def public(srv_id, %Status{} = t), do: add_metadata(t, srv_id)

  def public(srv_id, user_status) do
    case call_cb(srv_id, user_status) do
      {true, t} ->
        t

      false ->
        # Call status_public callback to handle unmatched statuses
        Malla.local(srv_id, :status_public, [user_status])
    end
    |> add_metadata(srv_id)
  end

  # defp status_internal(srv_id, status) do
  #   ref = rem(:erlang.phash2(:erlang.make_ref()), 10000)
  #   msg = "#{inspect(ref)}: #{inspect(status)} (#{srv_id})"
  #   Logger.warning("Malla reference " <> msg)
  #   %Status{status: "unknown_error", info: "Internal reference " <> string(ref)}
  # end

  defp call_cb(srv_id, user_status) do
    case Malla.local(srv_id, :status, [user_status]) do
      :continue ->
        false

      info when is_binary(info) ->
        {true, %Status{info: info} |> add_status(user_status)}

      list when is_list(list) ->
        {true, %Status{} |> add_opts(list) |> add_status(user_status)}
    end
  end

  @spec add_opts(%Status{}, [status_opt()]) :: %Status{}

  defp add_opts(%Status{} = status, []), do: status

  # legacy option
  defp add_opts(%Status{} = status, [{:msg, info} | rest]),
    do: add_opts(%Status{status | info: string(info)}, rest)

  defp add_opts(%Status{} = status, [{:info, info} | rest]),
    do: add_opts(%Status{status | info: string(info)}, rest)

  defp add_opts(%Status{} = status, [{:code, code} | rest]) when is_integer(code),
    do: add_opts(%Status{status | code: code}, rest)

  defp add_opts(%Status{} = status, [{:status, new_status} | rest]),
    do: add_opts(%Status{status | status: string(new_status)}, rest)

  defp add_opts(%Status{} = status, [{:data, data} | rest]) when is_list(data) or is_map(data) do
    list = if is_map(data), do: Map.to_list(data), else: data
    data = Map.new(for {k, v} <- list, do: {string(k), string(v)})
    add_opts(%Status{status | data: data}, rest)
  end

  defp add_opts(%Status{} = status, [{:metadata, data} | rest])
       when is_list(data) or is_map(data) do
    list = if is_map(data), do: Map.to_list(data), else: data
    data = Map.new(for {k, v} <- list, do: {string(k), string(v)})
    add_opts(%Status{status | metadata: data}, rest)
  end

  defp add_status(%Status{status: ""} = t, user_status),
    do: %Status{t | status: make_status(user_status)}

  defp add_status(t, _user_status), do: t

  defp add_metadata(status, srv_id),
    do: Malla.local(srv_id, :status_metadata, [status])

  defp make_status(user_status) when is_atom(user_status), do: to_string(user_status)
  defp make_status(user_status) when is_binary(user_status), do: user_status

  defp make_status(user_status) when is_tuple(user_status) and tuple_size(user_status) > 0,
    do: make_status(elem(user_status, 0))

  defp make_status(_), do: "unknown"

  @doc false
  @spec string(term) :: String.t()
  def string(term) when is_binary(term), do: term

  def string(term) do
    try do
      to_string(term)
    rescue
      _ ->
        inspect(term)
        # to_string(:io_lib.format(~c"~p", [term]))
    end
  end

  # @doc """
  # Safely formats a string using `:io_lib.format/2`.

  # Returns an empty string if formatting fails and logs a warning.

  # ## Examples

  #     iex> Malla.Status.to_fmt(~c"Hello ~s", ["world"])
  #     "Hello world"

  #     iex> Malla.Status.to_fmt(~c"Number: ~p", [42])
  #     "Number: 42"
  # """
  # @spec to_fmt(charlist, list) :: String.t()
  # def to_fmt(fmt, list) do
  #   try do
  #     to_string(:io_lib.format(fmt, list))
  #   rescue
  #     _ ->
  #       Logger.info("Invalid format API reason: #{inspect(fmt)}, #{inspect(list)}}~p")
  #       ""
  #   end
  # end

  defimpl String.Chars, for: Status do
    def to_string(%Status{status: status, info: info, code: code}),
      do: "<STATUS #{status} (#{code}): #{info}>"
  end

  # case user_status do
  #   {status, _}
  #   when status in [
  #          :badarg,
  #          :badarith,
  #          :function_clause,
  #          :if_clause,
  #          :undef,
  #          :timeout_value,
  #          :noproc,
  #          :system_limit
  #        ] ->
  #     status_internal(srv_id, user_status)

  #   {{status, _}, _}
  #   when status in [:badmatch, :case_clause, :try_clause, :badfun, :badarity, :nocatch] ->
  #     status_internal(srv_id, user_status)
end
