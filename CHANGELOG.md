# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `Malla.Service.del_plugin/2` with a plugin the service does not have returns
  `:ok` instead of crashing the service.
- A service declared with `paused: true` starts with the `:pause` admin status
  (it was `:paused`, which is not a valid admin status).
- When a plugin fails to start, the service stops exactly the plugins that
  are running (their children supervisors included, top-level first) and goes
  to `:failed` without a `:stopped` notification. Supervisors started in the
  failed round are no longer left running untracked, and `plugin_stop/2` is no
  longer called for plugins that never started. A plugin added at run-time
  that fails stops only the plugins started for it.
- A `plugins:` list that cannot be built no longer crashes the service:
  `Malla.Service.reconfigure/2` and `Malla.Service.add_plugin/3` (with
  `config:`) return `{:error, reason}`, and `start_link` fails with
  `{:error, reason}` instead of raising inside `init`.
- The internal `get_info_all` of the service server returns `[]` when there
  are no global services (it raised) and a proper list of infos otherwise.

### Changed
- Plugin groups (`use Malla.Plugin, group: ...`) now follow the documented
  order: each plugin depends on the previous one of its group in `plugins:`,
  so `[A, B, C]` starts `A -> B -> C` and callbacks run `C -> B -> A`. It was
  the reverse. Services that relied on the old order must reverse their list.
- `Malla.Cluster` (node connected) and `Malla.Plugins.Httpd.Lifecycle` (drain
  errors) log through `Logger` instead of printing with `IO.puts`.
- `Malla.Service.get_config/1` and `Malla.Service.get_status/1` each have their
  own doc (the status doc was on `get_config/1`).

## [0.0.1-rc.3] - 2026-11-13

### Added
- `:priority` option of `use Malla.Service` (default `0`).
  `Malla.Service.drain_all_local/0` drains the services of a node in
  that order, lowest first, and `GET /stop` of `Malla.Plugins.Httpd.Lifecycle`
  uses it.
- `httpd_lifecycle_drain_start/0` callback, called once by `GET /stop` before
  any service drains.
- `Malla.Util.redact`, `redact_args/2` and `secret_name?/1`.
- `Malla.Util.dynamic`, to hide a compile-time value from the type checker.
- `Malla.Util.validate_app!`, with `nimble_options` as an optional dependency.
- `config :malla, :remote_timeout`: default timeout of `Malla.remote/4`
  (15 000 ms when not set).

### Changed
- The `REQ` log lines of `Malla.Request` and `Malla.Plugins.Request` log the
  arguments through `Malla.Util.redact_args`.
- A remote exception (`{:malla_rpc_error, …}`) no longer becomes a public
  status with the exception text as `info`: it goes to `status_public/1`
  (logged under a reference, answered as `internal_error`).
- A runtime config update that carries `:priority` is refused, like the other
  `use` options.

### Deprecated
- `Malla.Node` reads an unprefixed `{:error, :service_not_available}` reply
  from a node on an older Malla as `:malla_service_not_available`, for clusters
  upgraded node by node. To be removed after 0.0.1.

### Fixed
- A callback that raised left the calling process with the callee's service
  id: it is now restored in an `after`.
- In chains of three or more modules, `{:cont, value}` with a value that is
  not a list was taken as the argument list; it now becomes `[value]`, as in
  two-module chains.
- `Malla.Node` no longer replaces the module of a local service with a
  proxy to a remote one when the local module exists but has not been
  loaded yet (interactive mode, as in development or `:peer` nodes): the
  service then failed with `malla_cb_in` undefined. The module is now
  loaded with `Code.ensure_loaded?/1` before deciding.

## [0.1.1] - 2023-10-05

### Added
- Initial release of Malla framework for distributed services in Elixir.
- Support for plugins, callbacks, service discovery, and instrumentation.
- Basic documentation and examples.

### Changed
- N/A

### Deprecated
- N/A

### Removed
- N/A

### Fixed
- N/A

### Security
- N/A