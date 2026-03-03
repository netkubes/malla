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

defmodule Malla.Plugins.Tracer do
  @moduledoc """
  Plugin that provides observability callbacks for Malla services.

  This module defines the callback interface that telemetry plugins can override
  to integrate with observability backends (OpenTelemetry, Datadog, etc.).

  For the user-facing API, see `Malla.Tracer`.

  For comprehensive documentation, see the guide:
  - **[Tracing and Instrumentation](guides/09-observability/01-tracing.md)**: For a guide on how to use the tracer.
  """

  use Malla.Plugin

  @optional_callbacks [
    malla_span: 3,
    malla_span_update: 1,
    malla_span_metric: 3,
    malla_span_event: 3,
    malla_span_log: 3,
    malla_span_error: 2,
    malla_span_labels: 1,
    malla_span_globals: 1,
    malla_span_info: 1,
    malla_span_get_base: 0
  ]

  ## ===================================================================
  ## Span Callbacks
  ## ===================================================================
  @type span_id :: Malla.Tracer.span_id()

  @doc """
  Creates a tracing span around the given code block.

  Called when user code uses `Malla.Tracer.span/2` or `span/3` macros.

  By default, it will simply:
  1. Call `Malla.metric([:malla, :tracer, :starts], %{counter: 1}, %{span_name: name, opts: opts})`
  2. Execute the code
  3. Call `Malla.metric([:malla, :tracer, :stops], %{counter: 1}, %{span_name: name, result: res})`
  """
  @callback malla_span(span_id, keyword, (-> any)) :: any
  defcb malla_span(name, opts, fun) do
    Malla.metric([:malla, :tracer, :starts], %{counter: 1}, %{span_name: name, opts: opts})
    res = fun.()
    Malla.metric([:malla, :tracer, :stops], %{counter: 1}, %{span_name: name, result: res})
    res
  end

  @doc """
  Update the current span with new attributes.

  Called when user code calls `Malla.Tracer.span_update/1`.

  By default it does nothing.
  """
  @callback malla_span_update(keyword) :: :ok
  defcb malla_span_update(_update), do: :ok

  @doc """
  Record a metric within a span.

  Called when user code calls `Malla.Tracer.metric/2` or `metric/3`.

  By default it calls `Malla.metric([:malla, :tracer, id], data, meta)`
  """
  @callback malla_span_metric(span_id, number | keyword | map, keyword | map) :: :ok
  defcb malla_span_metric(id, data, meta),
    do: Malla.metric([:malla, :tracer, id], data, meta)

  @doc """
  Record an event within a span.

  Called when user code calls `Malla.Tracer.event/1`, `event/2`, or `event/3`.

  By default it does nothing.
  """
  @callback malla_span_event(span_id, keyword | map, keyword | map) :: :ok
  defcb malla_span_event(_id, _data, _meta), do: :ok

  @doc """
  Log a message within the current span.

  Called when user code calls logging macros like `debug/1`, `info/1`, etc.

  By default it delegates to Elixir's `Logger.bare_log/3` with appropriate level mapping.
  """
  @callback malla_span_log(atom | pos_integer(), String.t() | (-> String.t()), keyword | map) ::
              :ok
  defcb malla_span_log(level, text, meta) do
    level_logger = Malla.Tracer.level_to_logger(level)
    meta = if is_map(meta), do: Map.to_list(meta), else: meta
    Logger.bare_log(level_logger, text, meta)
  end

  @doc """
  Record an error within the current span.

  Called when user code calls `Malla.Tracer.error/1` with a non-string value.

  It simply returns the error unchanged.
  """
  @callback malla_span_error(any, keyword | map) :: any
  defcb malla_span_error(error, _meta), do: error

  @doc """
  Set labels for the current span.

  Called when user code calls `Malla.Tracer.labels/1`.

  By default it does nothing.
  """
  @callback malla_span_labels(keyword | map) :: :ok
  defcb malla_span_labels(_labels), do: :ok

  @doc """
  Set global attributes that apply to all spans in this context.

  Called when user code calls `Malla.Tracer.globals/1`.

  By default it does nothing.
  """
  @callback malla_span_globals(keyword | map) :: :ok
  defcb malla_span_globals(_globals), do: :ok

  @doc """
  Retrieve information about the current span.

  Called when user code calls `Malla.Tracer.get_info/0` or `get_info/1`.

  By default it returns `nil`.
  """
  @callback malla_span_info(keyword) :: map | nil
  defcb malla_span_info(_opts), do: nil

  @doc """
  Get the base span context for propagation.

  Called when user code calls `Malla.Tracer.get_base/0`.

  By default it returns `nil`.
  """
  @callback malla_span_get_base :: any
  defcb malla_span_get_base(), do: nil
end
