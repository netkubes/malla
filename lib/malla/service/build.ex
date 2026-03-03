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
##
## -------------------------------------------------------------------

defmodule Malla.Service.Build do
  @moduledoc false
  # This module handles the dynamic compilation and generation of service dispatcher modules.
  # It creates modules that dispatch callback functions through a chain of plugins or modules,
  # allowing for modular and extensible service behavior in the Malla system.

  alias Malla.Service
  require Logger

  ## ===================================================================
  ## Dispatcher
  ## ===================================================================

  # Recompiles a service by dynamically generating and compiling a dispatcher module.
  # This module acts as a proxy that dispatches callback invocations to the appropriate
  # chain of modules defined in the service's plugin chain.
  def recompile(service) do
    %Service{id: srv_id} = service

    # Generate the AST (Abstract Syntax Tree) for the dispatcher module.
    # This includes setting module attributes like @service and injecting the callback functions.
    contents =
      quote do
        # @before_compile unquote(__MODULE__)
        @service unquote(Macro.escape(service))
        @moduledoc false
        unquote(Malla.Service.Build.callbacks())
      end

    # Create a unique module name by concatenating the service ID with 'MallaDispatch'.
    mod_name = Module.concat(srv_id, MallaDispatch)

    # Purge the old module version if it exists to avoid redefinition warnings
    :code.purge(mod_name)
    :code.delete(mod_name)

    # Dynamically create and compile the module from the generated AST, obtaining its binary representation.
    # We need to ensure debug_info is enabled to include abstract code in the binary
    old_opts = Code.compiler_options()
    _ = Code.compiler_options(debug_info: true)
    {:module, _, bin, _} = Module.create(mod_name, contents, Macro.Env.location(__ENV__))
    _ = Code.compiler_options(old_opts)

    # Extract the abstract code (AST) from the compiled module's binary for further processing.
    {:ok, {_, [{:abstract_code, {_, ac}}]}} = :beam_lib.chunks(bin, [:abstract_code])
    # Format the abstract code into a human-readable Erlang string representation,
    # removing file directives for cleaner output.
    out =
      :io_lib.fwrite(~c"~s~n", [:erl_prettypr.format(:erl_syntax.form_list(ac))])
      |> :re.replace("^\-file\(.*\)\.\n\n", "", [:global, :multiline])

    # Store the formatted dispatcher code in the service's config for debugging purposes.
    # Only used to debug
    Malla.Config.put(srv_id, :dispatcher_help, out)

    # Return the original service struct after recompilation.
    service
  end

  # Generates the AST for callback functions that will be injected into the dispatcher module.
  # This creates dispatch logic based on the service's callback definitions, handling chains
  # of modules that implement the same callback.
  def callbacks() do
    # Use quote to generate code that defines the callback functions within the dispatcher module.
    quote bind_quoted: [] do
      # Define a helper function to access the service struct from within the dispatcher.
      @doc false
      def service(), do: @service

      # Iterate over each callback defined in the service, generating a dispatch function for each.
      for {{name, arity}, modules} <- @service.callbacks do
        # Generate placeholder arguments for the function based on its arity.
        args = Macro.generate_arguments(arity, __MODULE__)

        # Create type specifications for the arguments (all typed as :any for simplicity).
        types = for _ <- 1..arity//1, do: {:any, [], []}

        # Dispatch based on the number of modules implementing this callback to optimize the call chain.
        case modules do
          [{module1, fun_name}] ->
            # If only one module implements the callback, call it directly without continuation logic.
            # if there is a single module, call it directly
            @doc false
            def unquote(name)(unquote_splicing(args)) do
              unquote(module1).unquote(fun_name)(unquote_splicing(args))
            end

          [{module1, fun_name1}, {module2, fun_name2}] ->
            # For two modules, call the first and process continuation to decide if the second should be called.
            # if there are only two modules, do a direct case

            @doc false
            def unquote(name)(unquote_splicing(args)) do
              result = unquote(module1).unquote(fun_name1)(unquote_splicing(args))
              process_continuation(result, unquote(module2), unquote(fun_name2), unquote(args))
            end

          _ ->
            # For three or more modules, use a recursive approach to handle the chain.
            # if there are more, use a slightly less efficient approach
            def unquote(name)(unquote_splicing(args)) do
              modules = unquote(modules)
              args = unquote(args)
              call_implemented_funs(modules, args)
            end
        end
      end

      # Handles continuation logic for a two-module chain: if the first module returns a continuation signal,
      # call the next module; otherwise, return the result as-is.
      defp process_continuation(result, next_mod, next_fun, args) do
        # Check the result from the first module to determine if continuation is needed.
        # Evaluate the result to decide on continuation for the remaining chain.
        case result do
          # If result is :cont or :continue, proceed to the next module with original args.
          atom when atom in [:cont, :continue] ->
            apply(next_mod, next_fun, args)

          # If result is {atom, new_args} with continuation atom and list args, call next with new args.
          {atom, new_args} when atom in [:cont, :continue] and is_list(new_args) ->
            apply(next_mod, next_fun, new_args)

          # If result is a tuple starting with continuation atom, extract new args and call next.
          tuple
          when is_tuple(tuple) and tuple_size(tuple) > 0 and elem(tuple, 0) in [:cont, :continue] ->
            [_ | new_args] = Tuple.to_list(tuple)
            apply(next_mod, next_fun, new_args)

          # For any other result, return it directly without continuation.
          # No continuation; return the result.
          other ->
            other
        end
      end

      # Base case for recursive callback chain: call the single remaining module.
      defp call_implemented_funs([{mod, fun_name}], args) do
        apply(mod, fun_name, args)
      end

      # Recursive case: call the first module, then process continuation for the rest.
      defp call_implemented_funs([{mod, fun_name} | rest], args) do
        # Apply the current module's function.
        result = apply(mod, fun_name, args)

        # Check if continuation is needed for the remaining modules.
        case process_continuation_multi(result, rest, args) do
          # If continuation, recurse with remaining modules and possibly new args; else return result.
          {^rest, new_args} -> call_implemented_funs(rest, new_args)
          other -> other
        end
      end

      # Similar to process_continuation, but for multi-module chains: returns a tuple indicating
      # whether to continue with the rest of the modules and updated args.
      defp process_continuation_multi(result, rest, args) do
        case result do
          # Continue with original args.
          atom when atom in [:cont, :continue] ->
            {rest, args}

          # Continue with new args.
          {atom, new_args} when atom in [:cont, :continue] ->
            {rest, new_args}

          # Extract new args from tuple and continue.
          tuple
          when is_tuple(tuple) and tuple_size(tuple) > 0 and elem(tuple, 0) in [:cont, :continue] ->
            [_ | new_args] = Tuple.to_list(tuple)
            {rest, new_args}

          other ->
            other
        end
      end
    end
  end

  # def inline_modules(service) do
  #   for plugin <- service.plugin_chain do
  #     IO.puts("P: #{inspect(plugin)}")
  #   end
  # end
end
