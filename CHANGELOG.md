# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

> **Pending release:** publish a new version with these changes (`mix.exs`
> is still at `0.0.1-rc.2`). Caracola needs the fix below, and depends on
> Malla by path (`{:malla, path: "../../malla"}`) until it is published.

### Fixed
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