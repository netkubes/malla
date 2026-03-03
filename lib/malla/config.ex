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

defmodule Malla.Config do
  @moduledoc """
  A simple ETS-based key-value store for node-wide configuration.

  This module provides utilities to store and retrieve data in an ETS table. It is
  useful for managing configuration or state that is global to a node and needs to
  be accessed from multiple services or processes.

  This store is local to each node and is not distributed.

  See the [Configuration guide](guides/07-configuration.md) for more details.
  """

  use GenServer

  @typedoc "A way to separate key spaces."
  @type domain :: term()

  ## ===================================================================
  ## Public
  ## ===================================================================

  @doc false
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]}
    }
  end

  @doc "Retrieves a value from the store. Returns `default` if not found."
  @spec get(domain(), term(), term()) :: value :: term()
  def get(domain, key, default \\ nil) do
    case :ets.lookup(__MODULE__, {domain, key}) do
      [] -> default
      [{_, value}] -> value
    end
  end

  @doc "Sets a value in the store."
  @spec put(domain(), term(), term()) :: :ok
  def put(domain, key, val) do
    true = :ets.insert(__MODULE__, {{domain, key}, val})
    :ok
  end

  @doc "Deletes a value from the store."
  @spec del(domain(), term()) :: :ok
  def del(domain, key) do
    true = :ets.delete(__MODULE__, {domain, key})
    :ok
  end

  @doc """
  Atomically increments or decrements a counter.

  You must previously set an initial value.
  """
  @spec increment(domain(), term(), integer()) :: integer()
  def increment(domain, key, count),
    do: :ets.update_counter(__MODULE__, {domain, key}, count)

  @doc "Updates a store key by applying a function to the current value. This operation is serialized."
  @spec update(domain(), term(), (domain() -> term())) :: :ok
  def update(domain, key, fun),
    do: GenServer.call(__MODULE__, {:update, domain, key, fun})

  @doc "Adds a value to a list stored in the store. The value is added only if it is not already present. Operation is serialized."
  @spec add(domain(), term(), term()) :: :ok | {:error, term()}
  def add(domain, key, val), do: GenServer.call(__MODULE__, {:add, domain, key, val})

  ## ===================================================================
  ## gen_server
  ## ===================================================================

  @doc false
  def start_link([]), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  @doc false
  def init([]) do
    _table = :ets.new(__MODULE__, [:named_table, :public, {:read_concurrency, true}])
    {:ok, {}}
  end

  @impl true
  @doc false
  def handle_call({:update, domain, key, fun}, _from, state) do
    old = get(domain, key)

    try do
      new = fun.(old)
      put(domain, key, new)
      {:reply, :ok, state}
    rescue
      error ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:add, domain, key, val}, _from, state) do
    reply =
      case get(domain, key) do
        nil ->
          put(domain, key, [val])
          :ok

        list when is_list(list) ->
          case Enum.member?(list, val) do
            true ->
              :ok

            false ->
              put(domain, key, [val | list])
          end

        _ ->
          {:error, :invalid_value}
      end

    {:reply, reply, state}
  end
end
