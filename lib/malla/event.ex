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

defmodule Malla.Event do
  @moduledoc false
  alias Malla.Event

  @default_remember_secs 1 * 60 * 60
  @remember_period_secs 5 * 60

  @type label_key :: atom | String.t()
  @type label_value :: String.t() | nil | :integer | :float | :boolean

  @type t :: %Event{
          uid: String.t(),
          class: :atom,
          service: module | String.t(),
          timestamp: NaiveDateTime.t(),
          payload: map,
          # recommended labels: group, resource, action, remote_ip, real_ip, user_id, user_uid, user_kind
          labels: %{label_key => label_value},
          metadata: %{
            :cluster => String.t(),
            :node => String.t(),
            :host => String.t(),
            optional(:first_timestamp) => DateTime.t(),
            optional(:count) => pos_integer,
            optional(:hash) => String.t(),
            optional(:weight) => pos_integer,
            optional(:target) => String.t() | [String.t()],
            optional(:action) => String.t(),
            optional(:resource) => String.t()
          }
        }

  defstruct uid: nil,
            class: nil,
            service: nil,
            timestamp: nil,
            payload: %{},
            labels: %{},
            metadata: %{}

  ## ===================================================================
  ## API
  ## ===================================================================

  @type event_opt ::
          {:service_id, Malla.id()}
          | {:payload, map | list}
          # Recommended labels: :group, :resource, :action, :target, :weight
          | {:labels, keyword | map}
          | {:metadata, keyword | map}
          | {:check_duplicates, boolean}

  @doc """
    Make an event object.

    If check_duplicates is true, the event will be remembered and, if a previous recent event
    with the same data is found:
    - uid is copied from there
    - first_timestamp is copied from the first event
    - counter is incremented (first one will be 1 in this case)
  """
  @spec make_event(atom, [event_opt]) :: %Event{}

  def make_event(class, opts \\ []) do
    service_id = Malla.get_service_id!(opts)
    labels = Keyword.get(opts, :labels, %{}) |> Map.new()
    meta = Keyword.get(opts, :metadata, %{}) |> Map.new()
    meta = Malla.get_service_meta(service_id) |> Map.delete(:service) |> Map.merge(meta)
    payload = Keyword.get(opts, :payload)

    event = %Event{
      uid: Malla.Util.make_timed_uid(),
      class: class,
      service: service_id |> Malla.get_service_name(),
      timestamp: NaiveDateTime.utc_now(),
      payload: if(payload == nil, do: %{}, else: Map.new(payload)),
      labels: labels,
      metadata: meta
    }

    if Keyword.get(opts, :check_duplicates, false), do: update_counter(event), else: event
  end

  ## ===================================================================
  ## gen_server
  ## ===================================================================

  use GenServer

  @ets :malla_events_store

  @doc "Supervisor specification"
  def child_spec([]),
    do: %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []}
    }

  def start_link() do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    _table = :ets.new(@ets, [:public, :named_table])
    send(self(), :arena_check_ets)
    {:ok, nil}
  end

  @impl true
  def handle_info(:arena_check_ets, state) do
    seconds = Malla.Application.get_env(:events_remember_secs, @default_remember_secs)
    remove_old_hashes(seconds)
    ets_memory = :ets.info(@ets, :memory) * :erlang.system_info(:wordsize)
    Malla.metric([:malla, :events, :remember_memory], ets_memory)
    Process.send_after(self(), :arena_check_ets, @remember_period_secs * 1000)
    {:noreply, state}
  end

  ## ===================================================================
  ## Private
  ## ===================================================================

  defp update_counter(event) do
    %Event{
      uid: uid,
      service: service,
      timestamp: timestamp,
      payload: payload,
      metadata: meta
    } = event

    ref = {service, :erlang.phash2(payload)}
    datetime = DateTime.from_naive!(timestamp, "Etc/UTC")
    {last_seconds, _} = DateTime.to_gregorian_seconds(datetime)
    entry = {ref, 0, uid, datetime, last_seconds}

    # increment counter position in 1 (counter)
    # entry will be used as default value in case is the first entry for this hash
    case :ets.update_counter(@ets, ref, {2, 1}, entry) do
      1 ->
        # there was no previous event entry,
        # so we just stored the first one
        # fields first_datetime is stored to be used in new copies
        # field last_seconds is used to delete old records
        meta =
          Map.merge(meta, %{
            hash: ref,
            first_timestamp: timestamp,
            count: 1
          })

        %{event | metadata: meta}

      _ ->
        [{^ref, count, uid, first_timestamp, _last_seconds}] = :ets.lookup(@ets, ref)
        # update last_seconds to last known value so we can delete old entries
        :ets.update_element(@ets, ref, {5, last_seconds})
        # change id, first_timestamp and counter
        meta =
          Map.merge(meta, %{
            hash: ref,
            first_timestamp: first_timestamp,
            count: count
          })

        %{event | uid: uid, metadata: meta}
    end
  end

  @doc """
    Removes ETS entries whose last time is older than x secs.
  """
  def remove_old_hashes(secs) do
    {now_seconds, _} = DateTime.utc_now() |> DateTime.to_gregorian_seconds()
    :ets.select_delete(@ets, [{{:_, :_, :_, :_, :"$5"}, [], [{:<, :"$5", now_seconds - secs}]}])
  end
end
