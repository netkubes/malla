defmodule Malla.UtilTest do
  @moduledoc false
  # Tests for Malla.Util helpers.

  use ExUnit.Case, async: true
  alias Malla.Util

  describe "keyword_merge/2" do
    test "adds keys that only exist in the update" do
      assert Util.keyword_merge([a: 1], b: 2) == [a: 1, b: 2]
    end

    test "replaces scalar values" do
      merged = Util.keyword_merge([a: 1, b: 2], a: 10)
      assert Keyword.get(merged, :a) == 10
      assert Keyword.get(merged, :b) == 2
    end

    test "deep-merges nested keyword lists instead of replacing them" do
      base = [my_plugin: [retries: 3, timeout: 1000]]
      update = [my_plugin: [retries: 5]]

      merged = Util.keyword_merge(base, update)
      nested = Keyword.get(merged, :my_plugin)

      assert Keyword.get(nested, :retries) == 5
      # timeout is preserved by the deep merge
      assert Keyword.get(nested, :timeout) == 1000
    end

    test "replaces plain (non-keyword) list values without raising" do
      base = [nodes: ["a@h", "b@h"]]
      update = [nodes: ["c@h"]]

      assert Util.keyword_merge(base, update) == [nodes: ["c@h"]]
    end

    test "replaces a value when only one side is a keyword list" do
      assert Util.keyword_merge([a: 5], a: [x: 1]) == [a: [x: 1]]
      assert Util.keyword_merge([a: [x: 1]], a: 5) == [a: 5]
    end
  end
end
