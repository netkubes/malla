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

defmodule Malla.Cluster do
  @check_nodes_time 5000

  @moduledoc """
  Provides utilities to connect Erlang nodes in a cluster.

  This module is designed to simplify node connection, especially in orchestrated
  environments like Kubernetes, by using DNS-based discovery.

  While Malla can work with any node connection method, this module provides
  a convenient, automated way to form a cluster.

  See the [Cluster Setup guide](guides/08-distribution/01-cluster-setup.md) for more details.

  This node also starts a `GenServer` that will monitor `:malla` application env variable
  `:malla_connect_nodes`, calling `connect/1` automatically each #{@check_nodes_time} milliseconds.

  """
  use GenServer
  require Logger

  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]}
    }
  end

  @doc """
    Tries to connect local node to one or serveral other nodes, trying different approaches.

    Entries are expected to be in either of the two following forms:
    * _name@domain_or_ip_
    * _domain_

    For each entry, we will try to identify the remote node and connect to it,
    unless already connected.

    In the first form, we first try to find if _domain_or_ip_ is a _DNS SRV_
    record. If we find none, we try to resolve it as an A record, and for each
    found ip, we try to connect to node `:'name@ip'`. If we found a _SRV_ record,
    we ignore _name_ and use names and ips from SRV info.

    In the second form, we only try to find SRV, and use names and ips from it.
  """
  @spec connect(String.t() | [String.t()]) :: :ok
  def connect(nodes) when is_binary(nodes),
    do: connect([nodes])

  def connect([]), do: :ok

  @dialyzer {:no_match, connect: 1}
  def connect([node | rest]) when is_binary(node) do
    case String.split(node, "@", parts: 2) do
      [name, domain] ->
        case resolve_service(domain) do
          [] -> [{name, resolve_host(domain)}]
          list -> list
        end

      [domain] ->
        resolve_service(domain)
    end
    |> do_connect()

    connect(rest)
  end

  @doc false
  def start_link([]),
    do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  @doc false
  def init([]) do
    Process.send_after(self(), :malla_connect_nodes, 5000)
    {:ok, nil}
  end

  @impl true
  @doc false
  def handle_info(:malla_connect_nodes, state) do
    Application.get_env(:malla, :connect, []) |> connect()
    Process.send_after(self(), :malla_connect_nodes, @check_nodes_time)
    {:noreply, state}
  end

  defp do_connect([]), do: :ok

  defp do_connect([{name, ips} | rest]) do
    nodes = [node() | Node.list()]

    for ip <- ips do
      node = String.to_atom("#{name}@#{ip}")

      if not Enum.member?(nodes, node) do
        case Node.connect(node) do
          true ->
            IO.puts("CONNECTED to #{node}")

          _ ->
            # IO.puts("NOT CONNECTED to #{node}")
            :ok
        end
      end
    end

    do_connect(rest)
  end

  # see problem on resolve_service
  @dialyzer {:no_match, resolve_host: 1}

  defp resolve_host(domain) do
    case :inet_res.getbyname(String.to_charlist(domain), :a) do
      {:ok, {:hostent, _, _, :inet, _, ips}} ->
        for(ip <- ips, do: to_string(:inet_parse.ntoa(ip)))

      _ ->
        []
    end
  end

  # It seems the spec for :inet_res.getbyname/2 is not correct
  # We also need to ignore resolve_service/3 and resolve_nodes/1
  # https://www.erlang.org/doc/man/dialyzer.html#type-warn_option
  @dialyzer {:no_match, resolve_service: 1}

  defp resolve_service(service) do
    case :inet_res.getbyname(String.to_charlist(service), :srv) do
      {:ok, {:hostent, _fullsrv, _list, :srv, _num_nodes, nodes}} ->
        resolve_service(nodes, [])

      o ->
        Logger.warning("Error in resolve for #{service}: #{inspect(o)}")
        []
    end
  end

  @dialyzer {:no_unused, resolve_service: 2}
  defp resolve_service([], acc), do: acc

  defp resolve_service([{_, _, _, name} | rest], acc) do
    [node, _] = String.split(to_string(name), ".", parts: 2)
    ips = resolve_host(to_string(name))
    resolve_service(rest, [{node, ips} | acc])
  end
end
