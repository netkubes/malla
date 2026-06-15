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

defmodule Malla.Plugins.Httpd.Lib do
  @moduledoc false
  defmacro callback() do
    quote do
      require Logger
      require Record

      @doc false
      def unquote(:do)(data) do
        data = put_elem(data, 0, :mod_cb)
        mod_cb(request_uri: uri, method: method, config_db: config_db) = data
        [profile: srv_id] = :ets.lookup(config_db, :profile)
        [server_name: name_chars] = :ets.lookup(config_db, :server_name)
        name = List.to_string(name_chars)
        Malla.put_service_id(srv_id)

        method =
          case method do
            ~c"GET" -> :get
            ~c"POST" -> :post
            ~c"PUT" -> :put
            ~c"HEAD" -> :head
            ~c"DELETE" -> :delete
            other -> List.to_string(other)
          end

        uri = uri |> List.to_string()

        try do
          {:reply, reply} = srv_id.httpd_request(name, method, uri, data)
          Malla.Plugins.Httpd.Lib.response(reply)
        rescue
          e ->
            Logger.error("Exception calling :httpd_request: #{inspect(e)}")
            Malla.Plugins.Httpd.Lib.response(code: 500, body: "Error")
        end
      end
    end
  end

  def response(reply) do
    code = Keyword.get(reply, :code, 200)
    body = Keyword.get(reply, :body, "")

    head =
      reply
      |> Keyword.drop([:code, :body])
      |> Enum.map(fn {key, value} -> {key, String.to_charlist(value)} end)
      |> Keyword.merge(
        code: code,
        content_length: Integer.to_charlist(byte_size(body))
      )

    {:proceed, [{:response, {:response, head, [body]}}]}
  end
end
