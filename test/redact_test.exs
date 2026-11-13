defmodule Malla.RedactTest do
  use ExUnit.Case, async: true

  alias Malla.Util

  test "secret-looking keys are hidden at any depth, other values kept" do
    term = %{
      login: "ana",
      password: "p",
      spec: %{password: "hash", contact: %{name: "Ana"}},
      tokens: %{"t1" => %{device: "web"}},
      list: [%{"client_secret" => "s", "id" => 1}],
      kw: [password: "x", a: 1]
    }

    assert Util.redact(term) == %{
             login: "ana",
             password: "[redacted]",
             spec: %{password: "[redacted]", contact: %{name: "Ana"}},
             tokens: "[redacted]",
             list: [%{"client_secret" => "[redacted]", "id" => 1}],
             kw: [password: "[redacted]", a: 1]
           }
  end

  test "structs and keys that are not names are left alone" do
    date = ~D[2026-10-01]

    assert Util.redact(%{{:a, 1} => %{token: "t"}, date: date}) ==
             %{{:a, 1} => %{token: "[redacted]"}, date: date}
  end

  test "the arguments of a call that handles a secret are hidden whole" do
    assert Util.redact_args(:set_password, ["uid", "pw", []]) == "[redacted]"
    assert Util.redact_args(:login, [%{user: "a"}]) == "[redacted]"
    assert Util.redact_args("login.check_password", %{login: "a", password: "b"}) == "[redacted]"
    assert Util.redact_args(:verify_token, ["jwt"]) == "[redacted]"
  end

  test "the arguments of any other call are redacted by key" do
    assert Util.redact_args("actor.get", %{uid: "x"}) == %{uid: "x"}

    assert Util.redact_args(:create_user, [%{login: "a", password: "p"}]) == [
             %{login: "a", password: "[redacted]"}
           ]
  end

  test "a config can be logged without its secrets" do
    config = [
      my_repo: [hostname: "db", username: "app", password: "pw", pool_size: 10],
      kafka: %{url: "kafka://user:pw2@broker:9092/x", api_key: "k"},
      my_verify: [repo: Repo, hmac_key: <<1, 2>>, enc_key: <<3, 4>>, issuer: "ACME"],
      name: "plain"
    ]

    assert Util.redact(config) == [
             my_repo: [hostname: "db", username: "app", password: "[redacted]", pool_size: 10],
             kafka: %{url: "kafka://user:[redacted]@broker:9092/x", api_key: "[redacted]"},
             my_verify: [
               repo: Repo,
               hmac_key: "[redacted]",
               enc_key: "[redacted]",
               issuer: "ACME"
             ],
             name: "plain"
           ]

    assert Util.redact("https://host/path?x=1") == "https://host/path?x=1"
  end
end
