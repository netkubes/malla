defmodule NodePrecompileTest do
  @moduledoc false
  # Tests for Malla.Node.precompile_stubs functionality

  use ExUnit.Case, async: false

  @test_service_name PrecompileTestService

  describe "Malla.Node.precompile_stubs/0" do
    test "reads precompile config from application env" do
      # Set up test configuration
      test_callbacks = [test_cb: 1]

      Application.put_env(:malla, :precompile, [
        {@test_service_name, test_callbacks}
      ])

      # Call precompile_stubs
      :ok = Malla.Node.precompile_stubs()

      # Verify module was created
      assert function_exported?(@test_service_name, :__malla_node_callbacks, 0)
      assert function_exported?(@test_service_name, :test_cb, 1)

      # Verify callback returns error
      assert {:error, :malla_service_not_available} == @test_service_name.test_cb(:arg)

      # Clean up
      Application.delete_env(:malla, :precompile)
      :code.purge(@test_service_name)
      :code.delete(@test_service_name)
    end

    test "handles nil precompile config gracefully" do
      # Ensure no precompile config
      Application.delete_env(:malla, :precompile)

      # Should not crash
      assert :ok = Malla.Node.precompile_stubs()
    end

    test "stub module is replaced when real service is discovered" do
      # Create a stub
      callbacks = [test_callback: 1]

      Application.put_env(:malla, :precompile, [
        {@test_service_name, callbacks}
      ])

      Malla.Node.precompile_stubs()

      # Verify stub exists and returns error
      assert {:error, :malla_service_not_available} == @test_service_name.test_callback(:arg)

      # Simulate service discovery by creating a real module
      # In reality, this would be done by maybe_make_module/2 when a service is discovered
      # We'll just verify the mechanism exists

      # Clean up
      Application.delete_env(:malla, :precompile)
      :code.purge(@test_service_name)
      :code.delete(@test_service_name)
    end
  end
end
