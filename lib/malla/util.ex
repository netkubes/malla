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
## "AS IS" BASIS, WITHOUT WARRANTIErun/iexS OR CONDITIONS OF ANY
## KIND, either express or implied.  See the License for the
## specific language governing permissions and limitations
## under the License.
##
## -------------------------------------------------------------------

defmodule Malla.Util do
  @moduledoc """
  Helpers for applications built with Malla.

  * `validate_app!/2` validates an application's environment against a
    `NimbleOptions` schema (only when the application depends on
    `:nimble_options`).
  * `keyword_merge/2` and `map_merge/2` are the deep merges that Malla uses for
    service configuration.
  * `redact/1`, `redact_args/2` and `secret_name?/1` hide secrets in terms
    before they are logged.

  The other functions of this module are used by Malla itself and are not part
  of its public API.
  """

  # Defined only when the application depends on :nimble_options (optional for Malla).
  if Code.ensure_loaded?(NimbleOptions) do
    @doc """
    Validates the environment of application `app` against a `NimbleOptions`
    `schema` and writes the validated values back (defaults included), so the
    rest of the application reads them with `Application.get_env/3`.

    Raises if the configuration is not valid. Meant for `c:Application.start/2`.
    Available only when the application depends on `:nimble_options`, an optional
    dependency of Malla.
    """
    @spec validate_app!(NimbleOptions.schema() | NimbleOptions.t(), atom) :: :ok
    def validate_app!(schema, app) do
      config = Application.get_all_env(app)

      case NimbleOptions.validate(config, schema) do
        {:ok, opts} ->
          for {key, val} <- opts, do: Application.put_env(app, key, val)
          :ok

        {:error, error} ->
          raise "Error validating config for app #{app}: #{inspect(error)}"
      end
    end
  end

  @doc false
  # Returns `term` as is. The type checker then sees any term instead of a
  # value fixed at compile time (a config read into a module attribute, a
  # switch that is off for now), so the branches for other values are not
  # reported as dead.
  @spec dynamic(term) :: term
  # A plain identity would carry the type of `term` across modules; the
  # process dictionary key is never set, so this always returns `term`.
  def dynamic(term), do: Process.get({__MODULE__, :dynamic}, term)

  @doc false
  def join_dots(nil), do: ""

  def join_dots(str) when is_binary(str), do: str

  def join_dots(atom) when is_atom(atom), do: to_string(atom)

  def join_dots(id) do
    case :persistent_term.get({:malla_join_dots, id}, nil) do
      nil ->
        trace_name = Enum.join(id, "::")
        :persistent_term.put({:malla_join_dots, id}, trace_name)
        trace_name

      trace_name ->
        trace_name
    end
  end

  @doc false
  # Generates an UID that is 27 bytes, sortable on time
  def make_timed_uid() do
    time = Integer.to_string(System.os_time(:millisecond), 32)
    # It works event for 2100
    9 = byte_size(time)
    time <> "-" <> make_uid()
  end

  @doc false
  # Generates a 18-byte random
  def make_uid() do
    bin =
      :crypto.hash(:sha, :erlang.term_to_binary({make_ref(), System.os_time(:microsecond)}))
      |> :binary.decode_unsigned()
      |> Integer.to_string(36)

    <<uid::binary-size(18), _::binary>> = bin
    uid
  end

  @doc """
  Deep merge of two maps: nested maps are merged, any other value of `update`
  replaces the one in `base`.
  """
  @spec map_merge(map, map) :: map

  def map_merge(base, update) do
    Map.merge(base, update, &map_merge_resolve/3)
  end

  defp map_merge_resolve(_key, left = %{}, right = %{}), do: map_merge(left, right)
  defp map_merge_resolve(_key, _left, right), do: right

  @doc """
  Deep merge of two keyword lists: when both values of a key are keyword lists
  they are merged, any other value of `update` (maps and plain lists included)
  replaces the one in `base`.
  """
  @spec keyword_merge(keyword, keyword) :: keyword

  def keyword_merge(base, update) do
    Keyword.merge(base, update, &keyword_merge_resolve/3)
  end

  # Only recurse when both sides are keyword lists; plain lists (and any other
  # value type) are replaced by the update, mirroring Keyword.merge/2 and
  # avoiding an ArgumentError when merging non-keyword lists.
  defp keyword_merge_resolve(_key, left, right) when is_list(left) and is_list(right) do
    if Keyword.keyword?(left) and Keyword.keyword?(right),
      do: keyword_merge(left, right),
      else: right
  end

  defp keyword_merge_resolve(_key, _left, right), do: right

  ## ===================================================================
  ## Redaction of secrets in logs
  ## ===================================================================

  @secret_key ~r/pass|secret|token|credential|api_?key|private_?key|hmac_?key|enc_?key/i
  # The password in a URL's user info: `scheme://user:password@host`.
  @url_password ~r{(://[^/:@\s]*:)[^@/\s]+@}

  @doc """
    Hides the values of secret-looking keys (`password`, `secret`, `token`,
    `credential`, `api_key`, `hmac_key`, `enc_key`, …) anywhere inside maps, keyword lists, lists
    and tuples, and the password of any URL (`ecto://user:pass@host`), so
    the term can be logged. Structs are kept as they are.
  """
  @spec redact(term) :: term

  def redact(%{__struct__: _} = term), do: term

  def redact(term) when is_map(term),
    do: Map.new(term, fn {key, value} -> redact_pair(key, value) end)

  def redact(term) when is_list(term) do
    Enum.map(term, fn
      {key, value} when is_atom(key) or is_binary(key) -> redact_pair(key, value)
      value -> redact(value)
    end)
  end

  def redact(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> redact() |> List.to_tuple()

  def redact(term) when is_binary(term),
    do: Regex.replace(@url_password, term, "\\1[redacted]@")

  def redact(term), do: term

  @doc """
    The arguments of a call `fun`, ready to be logged: all of them hidden when
    the name of the function says it handles a secret (`set_password`,
    `check_password`, `login`, `verify_token`, …), since the secret is
    then a positional argument with no key to recognise it by;
    `redact/1` otherwise.
  """
  @spec redact_args(atom | String.t(), term) :: term

  def redact_args(fun, args) do
    if secret_name?(fun), do: "[redacted]", else: redact(args)
  end

  @doc "Whether a key or function name looks like it holds a secret."
  @spec secret_name?(term) :: boolean

  def secret_name?(name) when is_atom(name) or is_binary(name) do
    name = to_string(name)
    Regex.match?(@secret_key, name) or Regex.match?(~r/(^|_|\.)login($|_|\.)/, name)
  end

  def secret_name?(_), do: false

  defp redact_pair(key, value) when is_atom(key) or is_binary(key) do
    if Regex.match?(@secret_key, to_string(key)),
      do: {key, "[redacted]"},
      else: {key, redact(value)}
  end

  defp redact_pair(key, value), do: {key, redact(value)}

  @doc false
  # Fast convert string or integer to base62. Mapping is '0-9, A-Z, a-z'
  @spec encode62(integer() | String.t()) :: String.t()
  def encode62(string) when is_binary(string), do: encode62(:binary.decode_unsigned(string))

  # 0-9 range, 0 -> '0'
  def encode62(num) when num < 10, do: <<num + 48>>
  # 10-35 range, 10 -> 'A'
  def encode62(num) when num < 36, do: <<num + 55>>
  # 36-61 range, 36 -> 'a', 61 -> 'z'
  def encode62(num) when num < 62, do: <<num + 61>>
  # >= 62 range, 62 -> '10'
  def encode62(num), do: encode62(div(num, 62)) <> encode62(rem(num, 62))

  @doc false
  # Generates a millisecond, time-based 9-byte string that can be sorted
  def sorted_time() do
    time = System.os_time(:millisecond) |> Integer.to_string(32)
    # true even for 2100
    9 = byte_size(time)
    time
  end
end
