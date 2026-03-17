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

defmodule Malla.Plugins.Base do
  @moduledoc """
  The base plugin that all services include by default.

  This module provides a set of essential callbacks that form the foundation of
  a Malla service's behavior. All services include this plugin in their dependency
  list, even if not explicitly declared.
  """

  use Malla.Plugin
  require Logger
  alias Malla.Service

  @type id :: Malla.id()
  @type class :: Malla.class()
  @type config :: map

  @optional_callbacks [
    service_init: 0,
    service_status_changed: 1,
    service_is_ready?: 0,
    service_drain: 0,
    service_cb_in: 3,
    malla_event: 2,
    malla_authorize: 3
  ]

  @type cont :: Malla.cont()
  @type user_state :: map

  ## ===================================================================
  ## Service Server Callbacks
  ## ===================================================================

  @doc """
  Called during service initialization, before the configuration phase.

  This callback is invoked once when the service starts, before `plugin_config/2`
  is called. It allows plugins to set up state or provide information that
  will be needed during configuration.

  Return `:ok` (or `:cont`) to continue initialization, or any other value
  to abort the init process.
  """

  @callback service_init() :: :ok | term
  defcb service_init(), do: :ok

  @doc """
  Called when the service status changes.

  This callback is called when the [_running_status_](`t:Malla.Service.running_status/0`) of the service
  changes. You should always return `:cont` so next plugin can receive the change too.

  The service information can be obtained using `Malla.get_service_id!/0` or by calling
  `service_module.service()` to get the full service struct.
  """

  @callback service_status_changed(Service.running_status()) :: :ok
  defcb service_status_changed(_status), do: :ok

  @doc """
    Called when `Malla.Service.is_ready?/1` is called.

    Each plugin must return either 'false' (when it is not ready) or 'cont' to go to next
    (when it is ready).
  """
  @callback service_is_ready?() :: boolean | cont
  defcb service_is_ready?(), do: true

  @doc """
    Called when `Malla.Service.drain/1` is called.

    Each plugin must prepare for stop, cleaning its state.

    If it could clean everything ok, it should return `:cont` to jump to next.
    If it could not, it should return `false`, meaning the drain could not complete,
    and it will be retried later.
  """

  @callback service_drain() :: boolean | cont

  defcb service_drain(), do: true

  @doc """
    Called from `Malla.remote/4` and functions in `Malla.Node` when a remote callback is received.
    By default it will simply call `apply(service_module, fun, args)` but you
    can override it in your plugins to add tracing, etc.
  """

  @callback service_cb_in(atom, list, keyword) :: any

  defcb service_cb_in(fun, args, _opts) do
    apply(Malla.get_service_id!(), fun, args)
  end

  @doc false
  # @doc """
  # Called when `Malla.event/2` is called.

  # It does nothing by default, but it should always return the same event.
  # """

  @callback malla_event(Malla.Event.t(), keyword) :: Malla.Event.t()
  defcb malla_event(event, _opts), do: event

  @doc """
    Called when `Malla.authorize/3` is called.

    By default it returns `{:error, :auth_not_implemented}`
  """
  @callback malla_authorize(term, term, Malla.authorize_opt()) ::
              boolean | {boolean, term} | {:error, term}

  defcb malla_authorize(_resource, _scope, _opts),
    do: {:error, :auth_not_implemented}
end
