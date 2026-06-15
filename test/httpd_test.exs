defmodule Malla.Plugins.HttpdTest do
  use ExUnit.Case, async: false

  # Service with multiple `:malla_httpd` entries — exercises the
  # `Keyword.get_values/2` loop in `Malla.Plugins.Httpd.plugin_start/2`.
  defmodule MultiServer do
    use Malla.Service,
      plugins: [Malla.Plugins.Httpd],
      malla_httpd: [port: 37010, name: "alpha"],
      malla_httpd: [port: 37011, name: "beta"]

    defcb httpd_request(name, method, path, _data) do
      {:reply, code: 200, body: "#{name} #{method} #{path}"}
    end
  end

  # Single-server service with a routed catch-all, used to verify
  # chain dispatch and falling through to the 404 in `Malla.Plugins.Httpd`.
  defmodule Routed do
    use Malla.Service,
      plugins: [Malla.Plugins.Httpd],
      malla_httpd: [port: 37012]

    defcb httpd_request(_name, :get, "/ping", _data), do: {:reply, code: 200, body: "pong"}
    defcb httpd_request(_name, _method, _path, _data), do: :cont
  end

  # Service using the Lifecycle plugin — exposes the Kubernetes probe routes.
  defmodule Probed do
    use Malla.Service,
      plugins: [Malla.Plugins.Httpd.Lifecycle],
      malla_httpd: [port: 37013]
  end

  setup_all do
    {:ok, _} = MultiServer.start_link()
    {:ok, _} = Routed.start_link()
    {:ok, _} = Probed.start_link()

    on_exit(fn ->
      # `stop/0` calls into the service and the GenServer exits while
      # replying, so the call itself raises `:normal`. Swallow it.
      Enum.each([MultiServer, Routed, Probed], fn mod ->
        try do
          mod.stop()
        catch
          :exit, _ -> :ok
        end
      end)
    end)

    :ok
  end

  describe "multi-server config" do
    test "each :malla_httpd entry starts its own listener" do
      assert {200, "alpha get /"} = http_get(37010, "/")
      assert {200, "beta get /"} = http_get(37011, "/")
    end

    test "both listeners handle independent paths" do
      assert {200, "alpha get /foo"} = http_get(37010, "/foo")
      assert {200, "beta get /bar"} = http_get(37011, "/bar")
    end

    test "callback receives the :name of the listener as the first arg" do
      assert {200, "alpha " <> _} = http_get(37010, "/whatever")
      assert {200, "beta " <> _} = http_get(37011, "/whatever")
    end
  end

  describe "request dispatch" do
    test "matched route returns plugin response" do
      assert {200, "pong"} = http_get(37012, "/ping")
    end

    test "unmatched route falls through Malla.Plugins.Httpd catch-all as 404" do
      assert {404, _} = http_get(37012, "/nope")
    end
  end

  describe "lifecycle plugin" do
    test "GET /node returns the current node name" do
      assert {200, body} = http_get(37013, "/node")
      assert body == Atom.to_string(node())
    end

    test "GET /is_ready reports readiness" do
      assert {200, _} = http_get(37013, "/is_ready")
    end

    test "GET /is_live reports liveness" do
      assert {200, _} = http_get(37013, "/is_live")
    end

    test "unmatched route falls through to the 404 catch-all" do
      assert {404, _} = http_get(37013, "/nope")
    end
  end

  # Erlang's built-in HTTP client — no external deps. Returns `{status, body}`.
  defp http_get(port, path) do
    url = ~c"http://localhost:#{port}#{path}"

    case :httpc.request(:get, {url, []}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} -> {status, body}
      {:error, reason} -> flunk("httpc request failed: #{inspect(reason)}")
    end
  end
end
