# Malla Migration Guide — Legacy API → Current API

This file is for AI coding assistants (and humans) migrating services built
against an older Malla release. Apply the transformations below mechanically;
each section includes before/after code so the edit is unambiguous.

See `AGENTS.md` in this same directory for the full current API.

---

## Breaking changes at a glance

| # | Change | Scope |
|---|--------|-------|
| 1 | `defcallback` → `defcb` | All chain callbacks |
| 2 | Lifecycle callbacks lost the trailing `service` arg | `plugin_config`, `plugin_start`, `plugin_stop`, `plugin_updated` |
| 3 | `Malla.Plugin.maybe_restart/3` removed | Replace with inline compare |
| 4 | `Malla.Plugin.merge_config/4` and `merge_config_multi/4` removed | Replace with `plugin_config_merge/3` (lifecycle) |
| 5 | `service_merge_config/2` chain callback removed | Use `plugin_config_merge/3` |
| 6 | `Malla.Service.Server.is_live?/is_ready?/drain/drain_all_local` moved / removed | `Malla.Service.is_live?/is_ready?/drain`; manual loop for drain-all |
| 7 | `Malla.callback/2,3` deprecated | Use `Malla.local/2,3` |
| 8 | `NimbleOptions` no longer transitive via Malla | Declare it directly |

`Malla.put_service_id/1`, `Malla.Service.Server.get_all_local/0`, and the
service-module dispatch syntax (`srv_id.my_callback(args)`) are **unchanged**.

---

## 1. `defcallback` → `defcb`

Rename every chain callback declaration.

```elixir
# BEFORE
defcallback httpd_request(method, path, data) do
  ...
end

# AFTER
defcb httpd_request(method, path, data) do
  ...
end
```

Applies to services (`use Malla.Service`) and plugins (`use Malla.Plugin`)
alike. `defcallback` is the legacy name and may emit a warning.

Lifecycle callbacks (`plugin_config`, `plugin_start`, `plugin_stop`,
`plugin_updated`, `plugin_config_merge`) are **not** `defcb` — keep them as
`def` with `@impl true`.

---

## 2. Drop the `service` arg from lifecycle callbacks

```elixir
# BEFORE
@impl true
def plugin_config(_srv_id, config, _service), do: ...

@impl true
def plugin_start(srv_id, config, _service), do: ...

@impl true
def plugin_stop(srv_id, config, _service), do: ...

@impl true
def plugin_updated(srv_id, old, new, _service), do: ...

# AFTER
@impl true
def plugin_config(_srv_id, config), do: ...

@impl true
def plugin_start(srv_id, config), do: ...

@impl true
def plugin_stop(srv_id, config), do: ...

@impl true
def plugin_updated(srv_id, old, new), do: ...
```

If the old implementation used `service`, retrieve what you need via
`Malla.get_service_id!()` or `srv_id.service()`.

Return shapes are unchanged:
- `plugin_start/2` → `:ok | {:ok, children: [child_spec]} | {:error, reason}`
- `plugin_updated/3` → `:ok | {:ok, restart: true} | {:error, reason}`
- `plugin_config/2` → `:ok | {:ok, config} | {:error, reason}`

---

## 3. `Malla.Plugin.maybe_restart/3` removed

Replace with an inline comparison of the relevant config slice.

```elixir
# BEFORE
@impl true
def plugin_updated(_srv_id, old, new, _service),
  do: Malla.Plugin.maybe_restart(old, :my_key, new)

# AFTER — single-value key
@impl true
def plugin_updated(_srv_id, old, new) do
  if old[:my_key] == new[:my_key] do
    :ok
  else
    {:ok, restart: true}
  end
end

# AFTER — multi-value key (keyword with duplicate keys)
@impl true
def plugin_updated(_srv_id, old, new) do
  if Keyword.get_values(old, :my_key) == Keyword.get_values(new, :my_key) do
    :ok
  else
    {:ok, restart: true}
  end
end
```

---

## 4 & 5. `service_merge_config/2` + `merge_config[_multi]/4` → `plugin_config_merge/3`

The old chain callback `service_merge_config/2` and its helper
`Malla.Plugin.merge_config_multi/4` are removed. The replacement is the
**lifecycle** callback `plugin_config_merge/3` — a regular `def` with
`@impl true`, not `defcb`.

```elixir
# BEFORE
defcallback service_merge_config(config, update) do
  Malla.Plugin.merge_config(config, :my_key, update)
end

# AFTER
@impl true
def plugin_config_merge(_srv_id, config, update) do
  case update[:my_key] do
    nil ->
      :ok  # nothing to merge, let other plugins / default handle it

    my_update ->
      merged = config |> Keyword.get(:my_key, %{}) |> Map.merge(my_update)
      {:ok, Keyword.put(config, :my_key, merged)}
  end
end
```

Return values:
- `:ok` — skip; framework continues with other plugins / default
- `{:ok, merged_config}` — replace config; next plugin sees this value
- `{:error, reason}` — reject the merge

**Gotcha — multi-entry keys (`merge_config_multi/4` protocol).** The old API
supported multiple entries under the same config key, identified by `:name`,
with a `$delete: true` flag for removals. The current framework finishes the
merge phase with `Keyword.merge(config, update)`, which collapses duplicate
keys. That means the `:name` / `$delete` reconfigure protocol cannot be
faithfully preserved. Two acceptable migration paths:

1. **Drop runtime multi-entry reconfigure.** Keep multi-entry support at
   initial config (in `plugin_config/2`), accept default shallow merge at
   reconfigure time, and restart the plugin whenever the key changes.
2. **Keep single-entry reconfigure only.** Document that runtime updates
   replace the whole key.

Both are simpler than the old protocol and cover the common cases.

---

## 6. `Malla.Service.Server` namespace shrunk

| Old | New |
|-----|-----|
| `Malla.Service.Server.is_live?(srv_id)` | `Malla.Service.is_live?(srv_id)` |
| `Malla.Service.Server.is_ready?(srv_id)` | `Malla.Service.is_ready?(srv_id)` |
| `Malla.Service.Server.drain(srv_id)` | `Malla.Service.drain(srv_id)` |
| `Malla.Service.Server.drain_all_local()` | _removed_ — iterate manually |
| `Malla.Service.Server.get_all_local()` | _unchanged_ |

Manual drain-all replacement:

```elixir
# BEFORE
Malla.Service.Server.drain_all_local()

# AFTER
Malla.Service.Server.get_all_local()
|> Enum.map(& &1.id)
|> Enum.all?(&Malla.Service.drain/1)
```

---

## 7. `Malla.callback/2,3` → `Malla.local/2,3`

```elixir
# BEFORE
Malla.callback(:my_fun, [arg1, arg2])
Malla.callback(MyService, :my_fun, [arg1, arg2])

# AFTER
Malla.local(:my_fun, [arg1, arg2])
Malla.local(MyService, :my_fun, [arg1, arg2])
```

Signatures are identical; only the name changed.

---

## 8. `NimbleOptions` no longer transitive

Older Malla releases pulled in `nimble_options` as a transitive dep. It is no
longer declared. If your plugin uses it (common in `plugin_config/2` schema
validation), add it to the consuming app's `mix.exs`:

```elixir
defp deps do
  [
    {:malla, "~> X.Y"},
    {:nimble_options, "~> 1.0"}
  ]
end
```

---

## Mechanical migration checklist

For each app being migrated:

1. **Grep for legacy identifiers** — any hit is a migration site:
   - `defcallback`
   - `def plugin_config(` / `def plugin_start(` / `def plugin_stop(` / `def plugin_updated(` — check arity
   - `Malla.Plugin.maybe_restart`
   - `Malla.Plugin.merge_config` / `merge_config_multi`
   - `service_merge_config`
   - `Malla.Service.Server.is_live?` / `is_ready?` / `drain` / `drain_all_local`
   - `Malla.callback(`
   - `NimbleOptions` usage without a direct dep
2. Apply the transformations above.
3. Run `mix compile --force` and resolve any errors or warnings.
4. Run `mix format` (fix `.formatter.exs` if it imports deps that no longer exist).
5. Run tests if present.

---

## What is NOT a migration task

These still work as before — don't touch them:

- `Malla.put_service_id/1` (set service context in process dictionary)
- Service dispatch via module: `srv_id.my_callback(args)`
- `Malla.Service.Server.get_all_local/0`
- `defcb` return values: `:cont | {:cont, [args]} | any_terminal_value`
- `plugin_start/2` child spec list shape
- `use Malla.Service, global: true, plugins: [...], vsn: "..."` options
