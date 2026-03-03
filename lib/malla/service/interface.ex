defmodule Malla.Service.Interface do
  @moduledoc """
  Behaviour defining the public interface for Malla services.

  Any module using `Malla.Service` will implement this behaviour,
  providing the standard API functions for starting, stopping,
  configuring, and querying the service readily available inserted
  in service module.

  Sice they live at ther service module, the service ID is already known
  (it is the module itself) so you don't need to provide it.

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
  Gets current service configuration, or `:unknown` if not started,
  """
  @callback get_config() :: keyword() | :unknown

  @doc """
  Gets current service configurartion, or `:unknown` if not started.
  """
  @callback get_status() :: Malla.Service.running_status() | :unknown

  @doc """
  This function is called from functions like `Malla.remote/3` to call services
  on remote nodes.

  Once it receives the call:
  * It sets process global leader to :user so that responses are not sent back to caller.
  * It sets current module as current service in process's dictionary.
  * It calls callback function `c:Malla.Plugins.Base.service_cb_in/3`.
  """
  @callback malla_cb_in(fun :: atom, args :: list, opts :: keyword) :: any
end
