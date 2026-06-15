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

defmodule Malla.Plugins.Httpd do
  @moduledoc """
    This module implements a `Malla.Plugin` to include in your `Malla.Service`,
    providing a super simple, dependency-free http server, useful to
    provide adminstrative information like Prometheus requests, Kubernetes Lifecycle,
    etc.

    It is built on Erlang's `:inets` `httpd` (already part of OTP), so it pulls
    in no extra web stack. It is intended for administrative surfaces —
    Prometheus scraping, Kubernetes health probes, internal introspection —
    where a full web framework would be overkill.

    It offers a single callback, `c:httpd_request/4` that will be called on
    each incoming request.

    To use it, include it in your service, for example

    ```
    defmodule MyService do
      use Malla.Service,
        plugins: [Malla.Plugins.Httpd],
        malla_httpd: [port: 3100]

      defcb httpd_request(name, method, path, data) do
        body =
          inspect(%{
            name: name,
            method: method,
            path: path,
            headers: Malla.Plugins.Httpd.get_headers(data),
            body: Malla.Plugins.Httpd.get_body(data)
          })

        {:reply, [code: 200, body: body, server: "MyTest"]}
      end
    end
    ```
    Configuration must be placed under `:malla_httpd` key.

    Currently, only recognized options are:
    - port (default will be 3500)
    - name (mandatory if you use several 'malla_httpd' entries, default will be "default")

    This plugin accepts multiple 'malla_httpd' entries, starting multiple servers.
    Use `Malla.Service.reconfigure/2` to replace the full `:malla_httpd` configuration at runtime;
    if the value changes, the plugin will restart its supervised children.

    For Kubernetes-style lifecycle endpoints (`/is_live`, `/is_ready`, `/stop`,
    `/node`) wired to Malla's readiness and drain callbacks, see
    `Malla.Plugins.Httpd.Lifecycle`.
  """

  use Malla.Plugin
  require Logger

  require Record
  Record.defrecordp(:mod_cb, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  @typedoc "Opaque request data handed to `c:httpd_request/4`; use `get_headers/1` and `get_body/1` to inspect it."
  @type request_data :: record(:mod_cb)

  ## ===================================================================
  ## API
  ## ===================================================================

  @type method :: :get | :post | :put | :head | :delete

  @doc "Utility to call from `c:httpd_request/4` callback to get headers"
  @spec get_headers(request_data) :: [{String.t(), String.t()}]
  def get_headers(mod_cb(parsed_header: headers)) do
    for {k, v} <- headers, do: {List.to_string(k), List.to_string(v)}
  end

  @doc "Utility to call from `c:httpd_request/4` to get the body body"
  @spec get_body(request_data) :: String.t()
  def get_body(mod_cb(entity_body: body)),
    do: List.to_string(body)

  ## ===================================================================
  ## Service callbacks
  ## ===================================================================

  @impl true
  def plugin_config(_srv_id, config), do: plugin_do_config(config)

  @impl true
  def plugin_start(srv_id, config) do
    children =
      for opts <- Keyword.get_values(config, :malla_httpd) do
        httpd_opts = [
          port: opts[:port],
          server_name: opts[:name] |> to_string() |> String.to_charlist(),
          server_root: ~c"/tmp",
          document_root: ~c"/tmp",
          profile: srv_id,
          modules: [__MODULE__]
        ]

        Logger.info("Starting malla_httpd server on port #{opts[:port]}")

        %{
          id: {:malla_httpd, to_string(opts[:name])},
          start: {:inets, :start, [:httpd, httpd_opts, :stand_alone]}
        }
      end

    {:ok, children: children}
  end

  @impl true
  def plugin_updated(_srv_id, old_config, new_config) do
    if Keyword.get_values(old_config, :malla_httpd) ==
         Keyword.get_values(new_config, :malla_httpd) do
      :ok
    else
      {:ok, restart: true}
    end
  end

  # Inject callback expected by Erlang's http server
  require Malla.Plugins.Httpd.Lib
  Malla.Plugins.Httpd.Lib.callback()

  ## ===================================================================
  ## Offered callbacks
  ## ===================================================================

  @type response ::
          {:code, pos_integer}
          | {:server, binary}
          | {:accept_ranges, binary}
          | {:allow, binary}
          | {:cache_control, binary}
          | {:content_MD5, binary}
          | {:content_encoding, binary}
          | {:content_language, binary}
          | {:content_length, binary}
          | {:content_location, binary}
          | {:content_range, binary}
          | {:content_type, binary}
          | {:date, binary}
          | {:etag, binary}
          | {:expires, binary}
          | {:last_modified, binary}
          | {:location, binary}
          | {:pragma, binary}
          | {:retry_after, binary}
          | {:body, binary}

  @doc """
  Callback invoked for every incoming request.

  ## Arguments

  - `name` — the `:name` of the `:malla_httpd` entry that received the request
    (as a `String.t()`, e.g. `"default"`, `"metrics"`, `"probes"`). Useful to
    dispatch differently when a service exposes several listeners.
  - `method` — HTTP method, one of `:get`, `:post`, `:put`, `:head`, `:delete`.
  - `path` — request path as a `String.t()` (e.g. `"/metrics"`), including any
    query string.
  - `data` — opaque `request_data` record; use `get_headers/1` to obtain a list
    of `{name, value}` string pairs and `get_body/1` to obtain the raw request
    body as a `String.t()`.

  ## Return value

  Must return `{:reply, response}` where `response` is a keyword list built
  from the entries below. Every value is a `binary` except `:code`, which is
  a `pos_integer`. All entries are optional; unspecified entries default to
  the server's usual behaviour (e.g. `:code` defaults to `200` when a `:body`
  is present).

  Status and body:
  - `:code` — HTTP status code, e.g. `200`, `404`, `500`.
  - `:body` — response body bytes, e.g. `"hello"` or an encoded payload.

  Response headers (values are the raw header string):
  - `:server` — `Server` header, e.g. `"MyApp/1.0"`.
  - `:accept_ranges` — `Accept-Ranges`, e.g. `"bytes"` or `"none"`.
  - `:allow` — `Allow`, e.g. `"GET, HEAD, OPTIONS"`.
  - `:cache_control` — `Cache-Control`, e.g. `"no-cache"` or `"max-age=3600"`.
  - `:content_MD5` — `Content-MD5`, base64-encoded digest, e.g. `"Q2hlY2s="`.
  - `:content_encoding` — `Content-Encoding`, e.g. `"gzip"`.
  - `:content_language` — `Content-Language`, e.g. `"en"`.
  - `:content_length` — `Content-Length` in bytes as a string, e.g. `"1024"`.
  - `:content_location` — `Content-Location`, e.g. `"/index.en.html"`.
  - `:content_range` — `Content-Range`, e.g. `"bytes 0-499/1234"`.
  - `:content_type` — `Content-Type`, e.g. `"application/json"` or
    `"text/plain; charset=utf-8"`.
  - `:date` — `Date` in RFC 7231 format, e.g. `"Tue, 15 Nov 2024 08:12:31 GMT"`.
  - `:etag` — `ETag`, e.g. `~s("abc123")`.
  - `:expires` — `Expires` in RFC 7231 format,
    e.g. `"Thu, 01 Dec 2024 16:00:00 GMT"`.
  - `:last_modified` — `Last-Modified` in RFC 7231 format,
    e.g. `"Wed, 21 Oct 2024 07:28:00 GMT"`.
  - `:location` — `Location`, e.g. `"/login"` or `"https://example.com/"`.
  - `:pragma` — `Pragma`, e.g. `"no-cache"`.
  - `:retry_after` — `Retry-After` as seconds or HTTP-date, e.g. `"120"`.
  """
  @callback httpd_request(String.t(), method, String.t(), request_data) ::
              {:reply, [response]}

  defcb httpd_request(_name, _method, _path, _data), do: {:reply, code: 404}

  ## ===================================================================
  ## Internal
  ## ===================================================================

  # Recognized options for each `:malla_httpd` entry.
  @httpd_keys [:port, :name]

  defp plugin_do_config(config, pos \\ 0, acc \\ [])

  defp plugin_do_config([], _pos, acc), do: {:ok, Enum.reverse(acc)}

  defp plugin_do_config([{:malla_httpd, opts} | rest], pos, acc) do
    def_name = if pos == 0, do: "default", else: "default-#{pos}"

    case validate_httpd_opts(opts, 3500 + pos, def_name) do
      {:ok, opts} -> plugin_do_config(rest, pos + 1, [{:malla_httpd, opts} | acc])
      {:error, _} = error -> error
    end
  end

  defp plugin_do_config([other | rest], pos, acc),
    do: plugin_do_config(rest, pos, [other | acc])

  defp validate_httpd_opts(opts, default_port, default_name) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_known_keys(opts),
           {:ok, port} <- validate_port(Keyword.get(opts, :port, default_port)),
           {:ok, name} <- validate_name(Keyword.get(opts, :name, default_name)) do
        {:ok, port: port, name: name}
      end
    else
      {:error, "invalid :malla_httpd config, expected a keyword list, got: #{inspect(opts)}"}
    end
  end

  defp validate_known_keys(opts) do
    case Enum.find(opts, fn {key, _value} -> key not in @httpd_keys end) do
      nil ->
        :ok

      {key, _value} ->
        {:error, "unknown :malla_httpd option #{inspect(key)}, allowed: #{inspect(@httpd_keys)}"}
    end
  end

  defp validate_port(port) when is_integer(port) and port > 0, do: {:ok, port}

  defp validate_port(other),
    do: {:error, ":malla_httpd :port must be a positive integer, got: #{inspect(other)}"}

  defp validate_name(name) when is_atom(name) or is_binary(name), do: {:ok, name}

  defp validate_name(other),
    do: {:error, ":malla_httpd :name must be an atom or string, got: #{inspect(other)}"}
end
