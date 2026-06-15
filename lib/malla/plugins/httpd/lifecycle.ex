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

defmodule Malla.Plugins.Httpd.Lifecycle do
  @moduledoc """
  Plugin that extends `Malla.Plugins.Httpd` with Kubernetes-style lifecycle endpoints.

  Provides the following HTTP endpoints:

  * `GET /node` — replies `200` with the current node name (as returned by
    `Kernel.node/0`, converted with `Atom.to_string/1`).
  * `GET /is_live` — invokes `Malla.Service.is_live?/1` on every locally
    started service. Replies `200` when all services report live, or `500`
    (with the offending service id in the body) otherwise. Typically used as
    a Kubernetes liveness probe so the pod is restarted if it stops being
    live for long enough.
  * `GET /is_ready` — invokes `Malla.Service.is_ready?/1` on every locally
    started service. Replies `200` when all services report ready, or `500`
    (with the offending service id in the body) otherwise. Typically used as
    a Kubernetes readiness probe so the pod is added to the service network
    only once it is ready.
  * `GET /stop` — drains every locally started service via
    `Malla.Service.drain/1`, and once all are drained invokes the
    `c:httpd_lifecycle_drain/0` callback to let services run any additional
    shutdown work. Replies `200` on success or `500` after ten failed retries
    (one second apart). Typically wired to the Kubernetes pre-stop hook so
    in-flight work can finish cleanly before the pod is killed.

  Requests that do not match any of the paths above fall through (`:cont`),
  letting other plugins handle them.

  To use, add the plugin to your service after `Malla.Plugins.Httpd`:

  ```
  defmodule MyApp.Service do
    use Malla.Service,
      plugins: [Malla.Plugins.Httpd, Malla.Plugins.Httpd.Lifecycle],
      malla_httpd: [port: 3100]
  end
  ```

  `Malla.Plugins.Httpd.Lifecycle` declares `Malla.Plugins.Httpd` as a plugin
  dependency, so listing only the former is enough.
  """

  use Malla.Plugin, plugin_deps: [Malla.Plugins.Httpd]
  require Logger

  ## ===================================================================
  ## Implemented callbacks
  ## ===================================================================

  defcb httpd_request(_name, :get, "/node", _data),
    do: {:reply, code: 200, body: Atom.to_string(node())}

  defcb httpd_request(_name, :get, "/is_live", _data), do: services() |> is_live()

  defcb httpd_request(_name, :get, "/is_ready", _data), do: services() |> is_ready()

  defcb httpd_request(_name, :get, "/stop", _data), do: drain()

  defcb httpd_request(_name, _method, _path, _data), do: :cont

  ## ===================================================================
  ## Offered callbacks
  ## ===================================================================

  @doc """
  Invoked by the `GET /stop` endpoint once every local service has been
  drained via `Malla.Service.drain/1`, allowing each service to run any
  additional shutdown work (flushing buffers, closing external connections,
  waiting for in-flight jobs, etc.).

  ## Return value

  - `true` — the custom drain is complete. `/stop` replies `200`.
  - `false` — the custom drain is still in progress. The plugin sleeps for
    one second and calls the callback again.

  The `/stop` handler retries the drain/callback cycle up to ten times; if
  `true` is never returned within that budget, `/stop` replies `500`.

  The default implementation returns `true` immediately, which is the right
  choice when no extra shutdown work is needed.
  """
  @callback httpd_lifecycle_drain() :: boolean
  defcb httpd_lifecycle_drain(), do: true

  ## ===================================================================
  ## Internal
  ## ===================================================================

  defp services(), do: Malla.Service.Server.get_all_local() |> Enum.map(& &1.id)

  @doc false
  def drain(tries \\ 10)

  def drain(tries) when tries > 0 do
    try do
      if drain_all_local() do
        Logger.notice("All services DRAINED")

        if Malla.local(:httpd_lifecycle_drain, []) do
          {:reply, code: 200}
        else
          Logger.warning("Custom drain not ready tries left")
          Process.sleep(1000)
          drain(tries - 1)
        end
      else
        Logger.warning("All services NOT DRAINED, #{tries} tries left")
        Process.sleep(1000)
        drain(tries - 1)
      end
    rescue
      e ->
        text = Exception.format(:error, e, __STACKTRACE__)
        IO.puts("Exception calling drain: #{text}, #{tries} tries left")
        Process.sleep(1000)
        drain(tries - 1)
    end
  end

  def drain(_tries) do
    IO.puts("Too many retries, giving up on drain")
    {:reply, code: 500}
  end

  defp drain_all_local() do
    services()
    |> Enum.all?(&Malla.Service.drain/1)
  end

  defp is_live([]) do
    {:reply, code: 200}
  end

  defp is_live([srv_id | rest]) do
    if Malla.Service.is_live?(srv_id) do
      is_live(rest)
    else
      msg = "Service #{inspect(srv_id)} is not live"
      Logger.warning(msg)
      {:reply, code: 500, body: msg}
    end
  end

  defp is_ready([]) do
    {:reply, code: 200}
  end

  defp is_ready([srv_id | rest]) do
    if Malla.Service.is_ready?(srv_id) do
      is_ready(rest)
    else
      msg = "Service #{inspect(srv_id)} is not ready"
      Logger.warning(msg)
      {:reply, code: 500, body: msg}
    end
  end
end
