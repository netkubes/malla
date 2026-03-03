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

defmodule Malla.Registry do
  @moduledoc """
  Provides process registration utilities.

  This module offers a simple way to register and look up processes by name,
  supporting both unique and duplicate name registrations. It is useful for
  managing worker processes within a service.

  See the [Storage and State guide](guides/10-storage.md) for more details.
  """

  @doc """
  Helper utility to register servers with arbitrary names.

  Returns a via tuple that can be used with GenServer and other OTP behaviors
  for process registration. Uses `Malla.ProcRegistry` which does not allow duplicates.

  ## Example

      GenServer.start_link(__MODULE__, [], name: Malla.Registry.via("my_name"))
  """
  def via(term), do: {:via, Registry, {Malla.ProcRegistry, term}}

  @doc """
  Registers the current process with a key and optional value.

  Uses `Malla.ProcRegistry` which does not allow duplicate registrations.
  If a process is already registered with the given key, returns an error.

  ## Examples

      Malla.Registry.register(:my_key)
      #=> {:ok, #PID<0.123.0>}

      Malla.Registry.register(:my_key, %{some: :data})
      #=> {:error, {:already_registered, #PID<0.123.0>}}
  """
  @spec register(term, term) :: {:ok, pid} | {:error, {:already_registered, pid}}
  def register(key, value \\ nil),
    do: Registry.register(Malla.ProcRegistry, key, value)

  @doc """
  Finds a process previously registered with `register/2` or `via/1`.

  Returns the PID if found, or `nil` otherwise.

  ## Examples

      Malla.Registry.whereis(:my_key)
      #=> #PID<0.123.0>

      Malla.Registry.whereis(:unknown_key)
      #=> nil
  """
  @spec whereis(term) :: pid | nil
  def whereis(key) do
    case lookup(key) do
      nil -> nil
      {pid, _} when is_pid(pid) -> pid
    end
  end

  @doc """
  Finds the process and value previously registered with `register/2`.

  Returns a tuple of `{pid, value}` if found, or `nil` otherwise.

  ## Examples

      Malla.Registry.lookup(:my_key)
      #=> {#PID<0.123.0>, %{some: :data}}

      Malla.Registry.lookup(:unknown_key)
      #=> nil
  """
  @spec lookup(term) :: {pid, term} | nil
  def lookup(key) do
    case Registry.lookup(Malla.ProcRegistry, key) do
      [{pid, value}] -> {pid, value}
      [] -> nil
    end
  end

  @doc """
  Registers the current process with a key and optional value.

  Uses `Malla.ProcStore` which allows duplicate registrations.
  Multiple processes can register with the same key.

  ## Examples

      Malla.Registry.store(:my_key)
      #=> {:ok, #PID<0.123.0>}

      Malla.Registry.store(:my_key, %{some: :data})
      #=> {:ok, #PID<0.124.0>}
  """
  @spec store(term, term) :: {:ok, pid}
  def store(key, value \\ nil),
    do: Registry.register(Malla.ProcStore, key, value)

  @doc """
  Unregisters the current process from a key in `Malla.ProcStore`.

  ## Examples

      Malla.Registry.unstore(:my_key)
      #=> :ok
  """
  @spec unstore(term) :: :ok
  def unstore(key), do: Registry.unregister(Malla.ProcStore, key)

  @doc """
  Finds all processes and values previously registered with `store/2`.

  Returns a list of `{pid, value}` tuples for all processes registered under the given key.

  ## Examples

      Malla.Registry.values(:my_key)
      #=> [{#PID<0.123.0>, :value1}, {#PID<0.124.0>, :value2}]
  """
  @spec values(term) :: [{pid, term}]
  def values(key), do: Registry.lookup(Malla.ProcStore, key)

  @doc """
  Finds all processes and values matching a pattern and guards.

  Allows pattern matching on the stored values using Erlang match specifications.

  ## Examples

      Malla.Registry.values(:my_key, {:_, :_, :"$1"})
      #=> [{#PID<0.123.0>, :value1}]
  """
  @spec values(term, atom | tuple, list) :: [{pid, term}]
  def values(key, pattern, guards \\ []),
    do: Registry.match(Malla.ProcStore, key, pattern, guards)

  @doc """
  Counts all processes matching a pattern and guards.

  Returns the number of processes registered under the given key that match
  the provided pattern and guards.

  ## Examples

      Malla.Registry.count(:my_key)
      #=> 2

      Malla.Registry.count(:my_key, {:_, :specific_value})
      #=> 1
  """
  @spec count(term, atom | tuple, list) :: integer
  def count(key, pattern \\ :_, guards \\ []),
    do: Registry.count_match(Malla.ProcStore, key, pattern, guards)
end
