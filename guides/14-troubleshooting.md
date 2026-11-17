# Troubleshooting Guide

Symptoms you may meet, what causes them, and how to look inside a service. Everything here comes from how Malla behaves; the error values are the ones the code returns.

## Looking inside

These work on any running node (from `iex`, a remote shell or `rpc`):

```elixir
# What does the service think it is? (a call to the service process)
{:ok, info} = Malla.Service.get_service_info(MyService)
info.running_status, info.admin_status, info.last_error, info.plugins

# Cached, cheap, :unknown if the process is not running
MyService.get_status()
MyService.get_config()

# The plugin chain, top to bottom, and the chain of one callback
MyService.service().plugin_chain
Malla.Service.get_callbacks(MyService, :my_callback)

# Which nodes run the service, and which node am I connected to?
Malla.Node.get_nodes(MyService)
Malla.Node.get_instances(MyService)
Node.list()

# Raw discovery: members of the process groups
:pg.get_members(Malla.Services2, MyService)
:pg.get_members(Malla.Services2, :all)

# Is it live / ready (what a probe would say)?
Malla.Service.is_live?(MyService)
Malla.Service.is_ready?(MyService)
```

## `Malla.ServiceIdMissing` ("service_id is missing")

**Symptom.** An exception from `Malla.get_service_id!/0` when you use `span`, `info`, `req`, `Malla.Request.request/4`, `Malla.metric/4`, `Malla.Status.public/1`, `Malla.authorize/3` or any `Malla.local/2`.

**Cause.** Those calls need to know which service they belong to, and take it from the process dictionary. Callbacks (`defcb`) and calls made through `Malla.remote/4` or `Malla.local/3` set it. A plain function that you call directly, a process that you spawn, an `iex` session or a test process do not have it.

**Fix.** Set it where the work starts: `Malla.put_service_id(MyService)`, or pass the `:service_id` option to the call that takes it (`span/3`, `Malla.Request.request/4`, `Malla.authorize/3`), or call the function through `Malla.local(MyService, :fun, args)`. As a global fallback, `config :malla, default_service_id: MyService` makes `get_service_id!/0` use that service (and log a warning each time it does).

## `{:error, :malla_service_not_available}`

**Symptom.** `Malla.remote/4` or `Malla.call` returns it; `Malla.Request` turns it into the status `"service_not_available"`. It can take about 5 seconds to come back.

**Cause and fix.** It means no node answered for that service. In order:

1. **The service is not running anywhere.** Check `Malla.Node.get_nodes(MyService)` on the calling node. A service is only listed while its running status is `:running`: not while it is `:starting`, `:paused`, `:failed` or `:stopped`. Look at `Malla.Service.get_service_info/2` on the node that should run it.
2. **The nodes are not connected.** `Node.list()` must show the other node. See "Malla.Cluster not connecting" below.
3. **The calling node has not discovered it yet.** Discovery is pushed when a service changes status and re-checked every 10 seconds; right after connecting it takes a moment. `Malla.Node.wait_for_services/2` waits for it.
4. **The name is wrong.** The service ID is the module name. With `req`, an `alias` is not expanded, so `req UserService.get(1)` asks for `UserService`, not `MyApp.UserService` (see [Request Handling](08-distribution/04-request-handling.md)).
5. **The service is paused.** A paused service is not offered, and `Malla.Plugins.Request` rejects requests with this error.

The call retries before it gives up: 5 times, one second apart (`sna_retries`, `retries_sleep_msec`). Pass `sna_retries: 0` when you want it to fail at once, for example in tests.

## `UndefinedFunctionError` on a remote plain function

**Symptom.** `MyService.my_function(1)` raises `UndefinedFunctionError` on a node that does not run the service, although `Malla.remote(MyService, :my_function, [1])` works.

**Cause.** On a node that has no `MyService` module, Malla generates a virtual module that has proxies only for callbacks (`defcb`). A function defined with plain `def` is not in it. Also, a virtual module does not exist until the service has been discovered.

**Fix.** Call plain functions with `Malla.remote/4` or `Malla.call`, or define the function as a callback (`defcb`). If the error happens right after connecting, wait for discovery (or use the `:precompile` setting, see [Service Discovery](08-distribution/02-service-discovery.md)). If the node has the module of its own code (the service is in your application), the call runs locally instead.

## A callback returns `:cont` or `{:cont, ...}` to the caller

**Symptom.** `MyService.my_callback(1)` returns `:cont` (or `{:cont, 5}`) instead of a value.

**Cause.** Every module in the chain returned a continuation, so the last one had nobody to pass the call to, and its raw return went back to the caller. For your own callbacks nothing in Malla provides a base implementation.

**Fix.** Make sure that the module at the bottom of the chain of that callback returns a real value. Check the chain with `Malla.Service.get_callbacks(MyService, :my_callback)`: the last entry is the one that must return a value. See [Callbacks](05-callbacks.md).

A related one: `{:cont, my_list}` with a callback of one argument that is a list calls the next module with `length(my_list)` arguments, and fails with `UndefinedFunctionError`. Wrap it: `{:cont, [my_list]}`.

## `FunctionClauseError` in a callback

**Cause.** A `defcb` without a catch-all clause received arguments it does not match. The exception is raised from your plugin and propagates to the caller; the rest of the chain is not asked.

**Fix.** Add `defcb name(_args), do: :cont` as the last clause, with one `_` per argument.

## `UndefinedFunctionError` for `malla_span/3`, `status/1`, `malla_request/3`, ...

**Cause.** The service uses a feature whose plugin is not in its chain: `span`/`info` need `Malla.Plugins.Tracer`; `Malla.Status` needs `Malla.Plugins.Status`; `Malla.Request` needs `Malla.Plugins.Request` on **both** sides (the called service answers `malla_request/3`). When the missing callback is on the other node, the caller sees it as `"internal_error"`, and the real error is in the log of the called node.

**Fix.** Add the plugin to the service: `plugins: [Malla.Plugins.Request]` brings in the tracer and status plugins.

## Plugin order surprises

**Symptom.** A plugin's callback is not called, or called after another one.

**Inspect.**

```elixir
MyService.service().plugin_chain
# [MyService, PluginA, PluginB, Malla.Plugins.Base]
Malla.Service.get_callbacks(MyService, :my_callback)
# [{{:my_callback, 1}, [{MyService, :my_callback_malla_service}, {PluginA, :my_callback}, ...]}]
```

The chain of a callback only has the modules that define it, in the order of the plugin chain.

**Rules to check** (see [Plugins](04-plugins.md)):

- A plugin sits **above** the plugins it depends on, so it is called **before** them. `plugin_deps: [AuthPlugin]` means "I run before AuthPlugin", not after.
- Independent plugins are called in the order of `plugins:`; the first listed is called first.
- A group `[A, B, C]` starts A, B, C and calls C, B, A. Groups only chain the plugins that you list in `plugins:`.
- `{Plugin, optional: true}` does not add the plugin: it only orders it if something else (a plugin that requires it, or the `plugins:` list) adds it.
- A plugin that returns a final value ends the chain: plugins below it are not called. A tracer plugin must depend on `Malla.Plugins.Tracer` (to be above it), otherwise the default `malla_span/3` may shadow it.
- `add_plugin/3` puts the plugin first in the `plugins:` list.
- The chain you see is the **last one built**, not necessarily the one in the source: `start_link(plugins: ...)`, `add_plugin/3`, `del_plugin/2` and `reconfigure(plugins: ...)` rebuild it, and the rebuilt chain stays loaded in the VM after the service stops.

## Service stuck in `:failed`

**Symptom.** `MyService.get_status()` is `:failed`; `Malla.Service.is_live?/1` is `false`.

**Look.** `{:ok, info} = Malla.Service.get_service_info(MyService)` and read `info.last_error` and `info.last_error_time`. The log has lines like `Service MyService (MyPlugin): start error: ...` and `status is 'failed': ...`. A `last_error` of `{:child_failed, plugin}` means the supervisor of that plugin's children went down (too many restarts).

**What the service does.** The service process stays up. While the admin status is `:active`, every 5 seconds it tries to start the plugins that are not running; when they all start, the status returns to `:running`. Each failed attempt stops the plugins that did start (calling `plugin_stop/2`) and sets `:failed` again, so `service_status_changed(:failed)` is called every time. With admin status `:pause` or `:inactive` a failed service is not retried.

**Fix.** Fix the cause that `last_error` names (a connection that is not there, an invalid configuration, a child that crashes in `init`), or, if it is a bad configuration, `reconfigure/2`. A service that is `:failed` for long is reported as not live: a Kubernetes liveness probe on `/is_live` restarts the pod. An exception raised in `plugin_start/2` is different: it crashes the service process (and a supervisor restarts it).

## `{:error, {:key_not_allowed_in_service_start, key}}`

**Symptom.** `start_link/1` fails (the linked caller gets an exit; `start_supervised/1` returns `{:error, {{:key_not_allowed_in_service_start, key}, child_spec}}`), or `reconfigure/2` returns `{:error, {:key_not_allowed_in_service_start, key}}`.

**Cause.** The runtime configuration (start options, the `config :my_app, MyService, ...` environment of `otp_app`, or a `reconfigure/2` update) carries one of `:class`, `:vsn`, `:global`, `:paused`, `:silent`, `:priority`, `:otp_app`. Those are options of `use Malla.Service` and cannot change at runtime.

**Fix.** Move the key to the `use Malla.Service` options, or rename your configuration key.

## `Malla.Cluster` not connecting

1. **It is not started.** Malla does not start `Malla.Cluster`. Add `Malla.Cluster` to your supervision tree; without it `config :malla, connect: [...]` is never read.
2. **Wrong key.** The setting is `config :malla, connect: [...]` (a list of strings, or a string). The first attempt is 5 seconds after the process starts.
3. **Wrong entry form.** `"name@domain"` looks for an SRV record first, then A records and connects to `name@<ip>`. `"domain"` alone only looks for SRV records, with no fall back to A records. The node names have the form `name@ip`, so the nodes must have been started with `--name` (long names) and an IP in the name, for example `RELEASE_NODE=myapp@10.1.2.3`.
4. **Cookie.** All nodes must have the same cookie.
5. **EPMD and ports.** EPMD (4369) and the distribution ports of the nodes must be reachable. SRV ports are ignored; Erlang gets the port from EPMD.
6. **DNS.** Each lookup that fails writes `Error in resolve for ...` to the log every 5 seconds. Check with `:inet_res.getbyname(~c"your.domain", :a)` and `:srv` from an `iex` on the node.
7. **Try by hand.** `Node.connect(:"myapp@10.1.2.3")` shows whether it is Malla or the network: `false` means the connection itself fails.

## Other things that look like bugs

- **Calls to a missing service take about 5 seconds** to fail: `sna_retries` (5) with one second between. Lower them for fast failure.
- **`Malla.Service.get/3` raises `ArgumentError`** ("the table identifier does not refer to an existing ETS table"): the service is not running, so its table does not exist.
- **A callback `service_status_changed/1` crashes the service** with a `MatchError`: the chain ended with a value other than `:ok`. Return `:cont`.
- **`Malla.remote/4` returns `{:error, {:malla_rpc_error, {error, text}}}`**: the remote function raised, or the call timed out (`%ErlangError{original: {:erpc, :timeout}}`), or the connection broke. The remote exception is in `error`; the formatted stacktrace is in `text`. Raise the `:timeout` option (default 15 000 ms, or `config :malla, remote_timeout:`) if it is only slow.
- **`Malla.Request` answers `"internal_error"` with `Internal reference NNNN`**: the real term is in the log of the node that produced it, next to the same number (`Malla reference NNNN: ...`). It is also what an error with no `status/1` clause becomes.
- **Changes to plugins are not seen after a restart of the service**: a restarted service uses the last chain that was built; to get the compile-time one again restart the node.
- **`reconfigure(plugins: ...)` adds a plugin but its `plugin_start/2` is late**: the new plugins are started by the next periodic check, up to 5 seconds later. `add_plugin/3` does it at once.
- **A paused service still runs its local callbacks**: pause only removes it from discovery, makes `is_ready?/1` false and makes `Malla.Plugins.Request` refuse new requests.

## Next Steps

- [Lifecycle](06-lifecycle.md), [Plugins](04-plugins.md), [Callbacks](05-callbacks.md) - the rules behind the symptoms.
- [Cluster Setup](08-distribution/01-cluster-setup.md), [Service Discovery](08-distribution/02-service-discovery.md), [Remote Calls](08-distribution/03-remote-calls.md) - distribution.
