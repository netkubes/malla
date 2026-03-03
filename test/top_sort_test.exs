defmodule TopSortTest do
  @moduledoc """
  Tests for the TopSort service module.

  This module tests the topological sorting functionality, ensuring items are ordered correctly based on their dependencies and that circular dependencies are detected.
  """
  use ExUnit.Case, async: true

  import Malla.Service.TopSort, only: [top_sort: 1]

  describe "top_sort" do
    test "orders items correctly when there are no cycles" do
      # Build a map of dependencies for quick lookup from the lib1 data
      deps_map = lib1() |> Map.new(fn {k, v} -> {k, v} end)
      {:ok, sorted} = top_sort(lib1())

      for i <- 0..(length(sorted) - 1) do
        lib = Enum.at(sorted, i)
        # Exclude self-dependencies (if any) since they don't need to be positioned before
        deps = Map.get(deps_map, lib, []) -- [lib]

        for dep <- deps do
          dep_i = Enum.find_index(sorted, &(&1 == dep))
          assert dep_i < i, "Dependency #{dep} should appear before #{lib} in the sorted list"
        end
      end
    end

    test "returns error for circular dependencies" do
      assert {:error, {:circular_dependencies, [:dw01, :dw04]}} == top_sort(lib2())
    end
  end

  defp lib1(),
    do: [
      {:des_system_lib,
       [:std, :synopsys, :std_cell_lib, :des_system_lib, :dw02, :dw01, :ramlib, :ieee]},
      {:dw01, [:ieee, :dw01, :dware, :gtech]},
      {:dw02, [:ieee, :dw02, :dware]},
      {:dw03, [:std, :synopsys, :dware, :dw03, :dw02, :dw01, :ieee, :gtech]},
      {:dw04, [:dw04, :ieee, :dw01, :dware, :gtech]},
      {:dw05, [:dw05, :ieee, :dware]},
      {:dw06, [:dw06, :ieee, :dware]},
      {:dw07, [:ieee, :dware]},
      {:dware, [:ieee, :dware]},
      {:gtech, [:ieee, :gtech]},
      {:ramlib, [:std, :ieee]},
      {:std_cell_lib, [:ieee, :std_cell_lib]},
      {:synopsys, []}
    ]

  defp lib2(),
    do: [
      {:des_system_lib,
       [:std, :synopsys, :std_cell_lib, :des_system_lib, :dw02, :dw01, :ramlib, :ieee]},
      {:dw01, [:ieee, :dw01, :dw04, :dware, :gtech]},
      {:dw02, [:ieee, :dw02, :dware]},
      {:dw03, [:std, :synopsys, :dware, :dw03, :dw02, :dw01, :ieee, :gtech]},
      {:dw04, [:dw04, :ieee, :dw01, :dware, :gtech]},
      {:dw05, [:dw05, :ieee, :dware]},
      {:dw06, [:dw06, :ieee, :dware]},
      {:dw07, [:ieee, :dware]},
      {:dware, [:ieee, :dware]},
      {:gtech, [:ieee, :gtech]},
      {:ramlib, [:std, :ieee]},
      {:std_cell_lib, [:ieee, :std_cell_lib]},
      {:synopsys, []}
    ]
end
