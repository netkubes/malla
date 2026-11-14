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

defmodule Malla.Service.TopSort do
  @moduledoc false
  @spec top_sort([{term, [term]}]) ::
          {:ok, [term]} | {:error, {:circular_dependencies, [term]}}

  def top_sort(library) do
    digraph = :digraph.new()

    try do
      topsort_insert(library, digraph)

      case :digraph_utils.topsort(digraph) do
        false ->
          vertices = :digraph.vertices(digraph)
          circular = top_sort_get_circular(vertices, digraph)
          {:error, {:circular_dependencies, circular}}

        _dep_list ->
          {:ok, stable_order(library, digraph)}
      end
    after
      true = :digraph.delete(digraph)
    end
  end

  # Kahn's algorithm over the (acyclic) digraph, building the result from the
  # end: of the items no pending item depends on, the one that comes first in
  # `library` is placed last (items only named as dependencies rank after the
  # listed ones, in order of first mention). So among items not ordered by
  # dependencies, the one listed first ends highest in a plugin chain (the chain
  # is this result reversed). The result does not depend on how :digraph orders
  # its vertices, which changes between Erlang/Elixir versions.
  defp stable_order(library, digraph) do
    ranked =
      for({name, _deps} <- library, do: name) ++ for({_, deps} <- library, dep <- deps, do: dep)

    rank = ranked |> Enum.uniq() |> Enum.with_index() |> Map.new()
    pending = Enum.sort_by(:digraph.vertices(digraph), &Map.fetch!(rank, &1))
    place(pending, digraph, %{}, [])
  end

  defp place([], _digraph, _placed, acc), do: acc

  defp place(pending, digraph, placed, acc) do
    # edges go from a dependency to its dependent
    next =
      Enum.find(pending, fn item ->
        Enum.all?(:digraph.out_neighbours(digraph, item), &Map.has_key?(placed, &1))
      end)

    place(List.delete(pending, next), digraph, Map.put(placed, next, true), [next | acc])
  end

  defp topsort_insert([], _digraph), do: :ok

  defp topsort_insert([{name, deps} | rest], digraph) do
    :digraph.add_vertex(digraph, name)

    Enum.each(
      deps,
      fn dep ->
        case dep do
          ^name ->
            :ok

          _ ->
            :digraph.add_vertex(digraph, dep)
            :digraph.add_edge(digraph, dep, name)
        end
      end
    )

    topsort_insert(rest, digraph)
  end

  defp top_sort_get_circular([], _digraph), do: []

  defp top_sort_get_circular([vertice | rest], digraph) do
    case :digraph.get_short_cycle(digraph, vertice) do
      false ->
        top_sort_get_circular(rest, digraph)

      vs ->
        :lists.usort(vs)
    end
  end
end
