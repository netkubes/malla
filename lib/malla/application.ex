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

defmodule Malla.Application do
  @moduledoc false
  use Application

  require Logger

  @application :malla

  def start(_type, _args) do
    set_cluster()
    Malla.Node.precompile_stubs()

    children = [
      # See functions in Malla.Registry
      {Registry, keys: :unique, name: Malla.ProcRegistry},
      {Registry, keys: :duplicate, name: Malla.ProcStore},
      # Malla.Event,
      Malla.Config,
      # Create PG scope "Malla.Services"
      %{
        id: Malla.PG.Scope,
        start: {:pg, :start_link, [Malla.Services2]}
      },
      Malla.Node
    ]

    opts = [strategy: :one_for_one, name: Malla.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def set_cluster() do
    :persistent_term.put(:malla_cluster, get_env(:cluster, ""))
    :persistent_term.put(:malla_node, to_string(node()))
  end

  def get_cluster(), do: :persistent_term.get(:malla_cluster)

  def get_node(), do: :persistent_term.get(:malla_node)

  def get_default_service_id(), do: get_env(:default_service_id)

  def put_default_service_id(service_id), do: put_env(:default_service_id, service_id)

  def get_env(key, default \\ nil), do: Application.get_env(@application, key, default)

  def put_env(key, value), do: Application.put_env(@application, key, value)
end
