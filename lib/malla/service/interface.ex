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
## "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
## KIND, either express or implied.  See the License for the
## specific language governing permissions and limitations
## under the License.
##
## -------------------------------------------------------------------

defmodule Malla.Service.Interface do
  @moduledoc """
  Behaviour defining the public interface for Malla services.

  Any module using `Malla.Service` will implement this behaviour,
  providing the standard API functions for starting, stopping,
  configuring, and querying the service readily available inserted
  in service module.

  Since they live in the service module, the service ID is already known
  (it is the module itself), so you don't need to provide it.

  You cannot override these functions, they are included here only for
  documentation purposes. Use the mechanism detailed in `Malla.Service`
  and `Malla.Plugin` to use Malla's plugin system.
  """

  @doc "Starts the service. See `Malla.Service.start_link/2`."
  @callback start_link() :: {:ok, pid()} | {:error, term()}

  @doc "Starts the service. See `Malla.Service.start_link/2`."
  @callback start_link(start_opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Stops the service. See `Malla.Service.stop/1`."
  @callback stop() :: :ok | {:error, term()}

  @doc """
  Provides a standard supervisor spec to start the Service.

  Restart will be _transient_ so supervisor will not restart it if we stop it with `c:stop/0`.
  Shutdown will be _infinity_ to allow plugins to stop.
  """

  @callback child_spec(start_opts :: keyword()) :: Supervisor.child_spec()

  @doc """
  Changes service running status. See `Malla.Service.set_admin_status/3`.
  """

  @callback set_admin_status(
              status :: :active | :pause | :inactive,
              reason :: atom()
            ) :: :ok | {:error, term()}

  @doc """
  Reconfigures the service in real time. See `Malla.Service.reconfigure/2`.
  """
  @callback reconfigure(config :: keyword()) :: :ok | {:error, term()}

  @doc """
  Gets the current service configuration, or `:unknown` if not started.
  """
  @callback get_config() :: keyword() | :unknown

  @doc """
  Gets the current running status of the service, or `:unknown` if not started.
  """
  @callback get_status() :: Malla.Service.running_status() | :unknown

  @doc false
  # Entry point of `Malla.remote/4` on the node that runs the service: sets the
  # group leader to :user, puts the module as the service ID and calls
  # `c:Malla.Plugins.Base.service_cb_in/3`. Called by generated code only.
  @callback malla_cb_in(fun :: atom, args :: list, opts :: keyword) :: any
end
