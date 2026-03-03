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
## "AS IS" BASIS, WITHOUT WARRANTIErun/iexS OR CONDITIONS OF ANY
## KIND, either express or implied.  See the License for the
## specific language governing permissions and limitations
## under the License.
##
## -------------------------------------------------------------------

defmodule Malla.Util do
  @moduledoc false
  require Logger

  # def validate_app!(schema, app) do
  #   config = Application.get_all_env(app)

  #   case NimbleOptions.validate(config, schema) do
  #     {:ok, opts} ->
  #       for {key, val} <- opts, do: Application.put_env(app, key, val)
  #       :ok

  #     {:error, error} ->
  #       raise "Error validating config for app #{app}: #{inspect(error)}"
  #   end
  # end

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

  # Generates an UID that is 27 bytes, sortable on time
  def make_timed_uid() do
    time = Integer.to_string(System.os_time(:millisecond), 32)
    # It works event for 2100
    9 = byte_size(time)
    time <> "-" <> make_uid()
  end

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
    Deep merge of two maps

    Keys in first map existing in second one will be replaced
  """
  @spec map_merge(map, map) :: map

  def map_merge(base, update) do
    Map.merge(base, update, &map_merge_resolve/3)
  end

  defp map_merge_resolve(_key, left = %{}, right = %{}), do: map_merge(left, right)
  defp map_merge_resolve(_key, _left, right), do: right

  @doc """
    Deep merge of two keyword lists

    Keys in first keyword list existing in second one will be replaced
  """
  @spec keyword_merge(keyword, keyword) :: keyword

  def keyword_merge(base, update) do
    Keyword.merge(base, update, &keyword_merge_resolve/3)
  end

  defp keyword_merge_resolve(_key, left, right) when is_list(left) and is_list(right),
    do: keyword_merge(left, right)

  defp keyword_merge_resolve(_key, _left, right), do: right

  # @type status :: Malla.Status.user_status()

  # @doc """
  #   Tries to connect to a series of nodes

  #   Node can be:
  #   * an atom, representing a single erlang node
  #   * a string with the form "name@domain.com", we will try to connect with it as is
  #   * a string with the form "name@domain", we will try to solve all ips for 'domain'
  #     and connect to them, for example to :"name@1.2.3.4"
  #   * a string with a single name, like "my.service". We will try to find a DNS SRV
  #     service named after this, and will connect to all found names and ips
  #     If a returned entry is node1.my.service.com, and my.service.com solves to
  #     1.2.3.4 and 4.3.2.1, we will connect to :"node1@1.2.3.4" and ":node1@4.3.2.1"
  # """
  # def connect([]), do: :ok

  # def connect([node | rest]) when is_atom(node) do
  #   all = [node() | Node.list()]

  #   if not Enum.member?(all, node) do
  #     # Can be :ignored, true, false
  #     if Node.connect(node) == true, do: Logger.notice("CONNECTED to node #{node}")

  #     connect(rest)
  #   end
  # end

  # def connect([node | rest]) when is_binary(node) do
  #   nodes = resolve_nodes(node)
  #   connect(nodes ++ rest)
  # end

  # @type wait_opt ::
  #         {:connect, [atom | String.t()]}
  #         | {:tries, pos_integer}
  #         | {:wait, pos_integer}

  # @doc """
  #   Waits until a service appears on the cluster
  #   At each try, it will try to connect to Malla configured nodes (see `connect/0`)
  #   and wait 5 seconds before next try

  # """
  # @spec wait_for_services([Malla.id()], [wait_opt]) :: boolean
  # def wait_for_services(services, opts \\ [])

  # def wait_for_services([], _opts), do: true

  # def wait_for_services([service_id | rest], opts) do
  #   tries = Keyword.get(opts, :tries, 5)

  #   if tries > 0 do
  #     connect(Keyword.get(opts, :connect, Malla.Application.get_env(:connect)))

  #     if Malla.Node.get_instances(service_id) == [] do
  #       msg1 = "Could not connect to service #{inspect(service_id)}"
  #       time = Keyword.get(opts, :wait, 500)
  #       msg2 = " (#{tries} tries left) (#{time}msecs)"
  #       Logger.info(msg1 <> msg2)
  #       Process.sleep(time)
  #       opts = Keyword.merge(opts, tries: tries - 1, wait: 2 * time)
  #       wait_for_services([service_id | rest], opts)
  #     else
  #       wait_for_services(rest, opts)
  #     end
  #   else
  #     false
  #   end
  # end

  # def recompile(mod) do
  #   info = mod.module_info
  #   source = to_string(info[:compile][:source])

  #   try do
  #     Code.compile_file(source)
  #     :ok
  #   catch
  #     _, y ->
  #       {:error, y}
  #   end
  # end

  # #  @spec config_eval(String.t(), list) :: String.t()
  # #  # We could also add <% import %> at the beginning
  # #  def config_eval(string, assigns \\ []),
  # #    do: EEx.eval_string(string, [{:assigns, assigns}], functions: [{__MODULE__, [os_env: 1]}])

  # #  @spec os_env(atom | charlist | String.t()) :: String.t()
  # #  def os_env(env), do: System.get_env(to_string(env))

  # #  def hex(bin) when is_binary(bin), do: Base.encode16(bin)
  # #  def hex(list) when is_list(list), do: Base.encode16(:erlang.list_to_binary(list))
  # #  def hex(int) when is_integer(int), do: Base.encode16(:binary.encode_unsigned(int))
  # #
  # @spec apply(module, atom, list) ::
  #         term | :not_exported | {:exception, term, term}

  # def apply(mod, fun, args) do
  #   case :erlang.function_exported(mod, fun, length(args)) do
  #     false ->
  #       :not_exported

  #     true ->
  #       try do
  #         :erlang.apply(mod, fun, args)
  #       rescue
  #         exception ->
  #           {:exception, Exception.message(exception), __STACKTRACE__}
  #       end
  #   end
  # end

  # def console_debug(), do: set_console_level(:debug)

  # def console_info(), do: set_console_level(:info)

  # def console_notice(), do: set_console_level(:notice)

  # def console_warning(), do: set_console_level(:warn)

  # def console_error(), do: set_console_level(:error)

  # def set_console_level(level), do: Logger.configure_backend(:console, level: level)

  # def logger_format(level, msg, {_date, time}, _metadata) do
  #   try do
  #     node =
  #       case Malla.Application.get_node() do
  #         "nonode" <> _ -> ""
  #         node -> node
  #       end

  #     time = Logger.Formatter.format_time(time)
  #     meta = Malla.get_service_meta(nil)

  #     if level not in [:debug, :info],
  #       do: :telemetry.execute([:malla, :logger], %{value: 1}, Map.put(meta, :level, level))

  #     "#{time} [#{level}] (#{node}) #{msg}\n"
  #   rescue
  #     _ ->
  #       "ERROR in logger_format: #{inspect({level, msg})}\n"
  #   end
  # end

  # def pp(mod) do
  #   file = :code.which(mod)
  #   data = File.read!(file)
  #   {:ok, {_, [{:abstract_code, {_, ac}}]}} = :beam_lib.chunks(data, [:abstract_code])
  #   :io.fwrite('~s~n', [:erl_prettypr.format(:erl_syntax.form_list(ac))])
  # end

  # @doc """
  #   Converts a deep map into a keyword list
  # """

  # @spec to_list(map | list) :: list

  # def to_list([]), do: []

  # def to_list(map) when is_map(map), do: to_list2(map)

  # def to_list([{_, _} | _] = list), do: to_map2(list)

  # defp to_list2(term) when is_map(term), do: to_list3(Map.to_list(term), [])

  # defp to_list2([{_, _} | _] = list), do: to_list3(list, [])

  # defp to_list2([]), do: []

  # defp to_list2(list) when is_list(list), do: for(t <- list, do: to_list2(t))

  # defp to_list2(other), do: other

  # defp to_list3([{k, v} | rest], acc), do: to_list3(rest, [{k, to_list2(v)} | acc])

  # defp to_list3([], acc), do: Enum.reverse(acc)

  # @doc """
  #   Converts a possible deep keyword list or map to a map
  # """
  # @spec to_map(map | list) :: map

  # def to_map([]), do: %{}

  # def to_map(map) when is_map(map), do: to_map2(map)

  # def to_map([{_, _} | _] = list), do: to_map2(list)

  # defp to_map2(term) when is_map(term), do: to_map3(Map.to_list(term), [])

  # defp to_map2([{_, _} | _] = list), do: to_map3(list, [])

  # defp to_map2([]), do: %{}

  # defp to_map2(list) when is_list(list), do: for(t <- list, do: to_map2(t))

  # defp to_map2(other), do: other

  # # in subelements, we dont't want [] to be %{}
  # defp to_map3([{k, []} | rest], acc), do: to_map3(rest, [{k, []} | acc])

  # defp to_map3([{k, v} | rest], acc), do: to_map3(rest, [{k, to_map2(v)} | acc])

  # defp to_map3([], acc), do: Map.new(acc)

  # def filter_keys(map, fun) when is_map(map), do: filter_keys(Map.to_list(map), fun)

  # def filter_keys(list, fun) when is_list(list), do: filter_keys(list, fun, [])

  # defp filter_keys([], _fun, acc), do: Map.new(acc)

  # defp filter_keys([{key, val} | rest], fun, acc) do
  #   case fun.(key) do
  #     nil -> filter_keys(rest, fun, acc)
  #     key2 -> filter_keys(rest, fun, [{key2, val} | acc])
  #   end
  # end

  # @doc """
  #   Normalizes a map, updating all keys into atoms, if they exist, otherwise
  #   they are left as their original format
  # """
  # @spec normalize_map(map) :: map

  # def normalize_map(map), do: do_normalize_map(map)

  # def do_normalize_map(map) when is_map(map) do
  #   for {key, val} <- map, into: %{} do
  #     val = do_normalize_map(val)

  #     cond do
  #       is_atom(key) ->
  #         {key, val}

  #       is_binary(key) ->
  #         case to_atom("Elixir." <> key) do
  #           mod when is_atom(mod) ->
  #             {mod, val}

  #           _ ->
  #             case to_atom(key) do
  #               atom when is_atom(atom) -> {atom, val}
  #               _ -> {key, val}
  #             end
  #         end

  #       true ->
  #         {key, val}
  #     end
  #   end
  # end

  # def do_normalize_map(other), do: other

  # defp to_atom(string) do
  #   try do
  #     String.to_existing_atom(string)
  #   rescue
  #     _ -> string
  #   end
  # end

  # @doc """
  #   Normalized deep merge of two maps

  #   Keys in first map existing in second one will be replaced
  #   They will be converted first to atoms, if possible
  # """
  # @spec normalized_map_merge(map, map) :: map

  # def normalized_map_merge(base, update),
  #   do: map_merge(normalize_map(base), normalize_map(update))

  # @doc """
  #   Tries several ways to resolve connections to erlang nodes

  #   - If host has the form name@domain.with.dot, :"name@<solved_ips>" is returned
  #   - If it is like name@domain, :"name@domain" is returned
  #   - If it has no "@", it is considered a DNS service
  #     Combinations of names extracted from service and using the service as a name
  #     with the solved ips are returned
  #     For K8s stateful, names are returned for ClusterIP services (with a port)
  #     and using serviceName key
  #     For K8s deployment, names are not useful, so we try nodes with the same name
  #     as the service
  # """
  # # see problem on resolve_service
  # @dialyzer {:no_match, resolve_nodes: 1}

  # def resolve_nodes(node) when is_atom(node), do: [node]

  # def resolve_nodes(host) do
  #   case String.split(host, "@") do
  #     [name, host] ->
  #       if String.contains?(host, ".") do
  #         # for name@domain.com, leave it
  #         [String.to_atom(name <> "@" <> host)]
  #       else
  #         # for name@domain, try to find ips for domain
  #         for ip <- resolve_host(host), do: String.to_atom(name <> "@" <> ip)
  #       end

  #     [host] ->
  #       # if no @ is found, try service, then node
  #       case resolve_service(host) do
  #         [] ->
  #           for ip <- resolve_host(host), do: String.to_atom(host <> "@" <> ip)

  #         nodes ->
  #           nodes
  #       end
  #   end
  # end

  # defp resolve_host(host) when is_list(host) do
  #   case :inet_res.getbyname(host, :a) do
  #     {:ok, {:hostent, _, _, :inet, _, ips}} ->
  #       for(ip <- ips, do: to_string(:inet_parse.ntoa(ip)))

  #     _ ->
  #       []
  #   end
  # end

  # defp resolve_host(host) when is_binary(host), do: resolve_host(String.to_charlist(host))

  # # It seems the spec for :inet_res.getbyname/2 is not correct
  # # We also need to ignore resolve_service/3 and resolve_nodes/1
  # # https://www.erlang.org/doc/man/dialyzer.html#type-warn_option
  # @dialyzer {:no_match, resolve_service: 1}

  # @spec resolve_service(String.t()) :: [String.t()]
  # defp resolve_service(service) do
  #   case :inet_res.getbyname(String.to_charlist(service), :srv) do
  #     {:ok, {:hostent, _fullsrv, _list, :srv, _num_nodes, nodes}} ->
  #       resolve_service(service, nodes, [])

  #     _ ->
  #       []
  #   end
  # end

  # @dialyzer {:no_unused, resolve_service: 3}

  # defp resolve_service(_service, [], acc), do: acc

  # defp resolve_service(service, [{_, _, _, name} | rest], acc) do
  #   [node, _] = String.split(to_string(name), ".", parts: 2)
  #   ips = resolve_host(name)
  #   nodes1 = for ip <- ips, do: String.to_atom(node <> "@" <> ip)
  #   nodes2 = for ip <- ips, do: String.to_atom(service <> "@" <> ip)
  #   resolve_service(service, rest, acc ++ nodes1 ++ nodes2)
  # end

  # def backoff(fun, opts \\ []) do
  #   tries = Keyword.get(opts, :tries, 5)

  #   case fun.() do
  #     {:repeat, error} when tries > 1 ->
  #       id = Keyword.get(opts, :id, inspect(fun))
  #       sleep = Keyword.get(opts, :sleep, 250)
  #       Logger.warning("Error calling backoff for #{id} (#{inspect(error)}}. #{tries} left")
  #       Process.sleep(sleep)
  #       backoff(fun, Keyword.merge(opts, tries: tries - 1, sleep: sleep * 2))

  #     {:repeat, error} ->
  #       {:error, error}

  #     other ->
  #       other
  #   end
  # end

  @doc """
    Fast convert string or integer to base62
    Mapping is '0-9, A-Z, a-z'
  """
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

  # Generates a millisecond, time-based 9-byte string that can be sorted
  def sorted_time() do
    time = System.os_time(:millisecond) |> Integer.to_string(32)
    # true even for 2100
    9 = byte_size(time)
    time
  end

  # def get_callback(service_id, name) do
  #   for {{^name, arity}, plugins} <- service_id.service.callbacks, do: {arity, plugins}, into: %{}
  # end

  # def map_get_deep(map, [last]), do: Map.get(map, last)

  # def map_get_deep(map, [pos | rest]) do
  #   case Map.get(map, pos) do
  #     map when is_map(map) -> map_get_deep(map, rest)
  #     _ -> nil
  #   end
  # end

  # def map_put_deep(map, [last], value), do: Map.put(map, last, value)

  # def map_put_deep(map, [pos | rest], value) do
  #   case Map.get(map, pos) do
  #     submap when is_map(submap) ->
  #       submap = map_put_deep(submap, rest, value)
  #       Map.put(map, pos, submap)

  #     nil ->
  #       submap = map_put_deep(%{}, rest, value)
  #       Map.put(map, pos, submap)

  #     _ ->
  #       raise "path error"
  #   end
  # end

  # defimpl String.Chars, for: PID do
  #   def to_string(pid) when is_pid(pid),
  #     do: :erlang.list_to_binary(:erlang.pid_to_list(pid))
  # end
end
