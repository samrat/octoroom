defmodule Octoroom.Store do
  @moduledoc """
  Where Octoroom keeps what must outlive a room server or a node restart:
  room records and adapter records. A small key-value behaviour, so it can
  sit on ETS, Postgres or Redis.

  Two tables:

    * `:rooms`: room id => `%{run: run_id, assigns: map, updated_at: unix_ms}`.
      Written when a room server starts and when its assigns change, deleted
      when the room stops because its last participant left. A record left
      behind means the room didn't stop cleanly, so the next room server with
      that id recovers it.
    * `:adapters`: a key made before the adapter exists =>
      `%{room_id, run, adapter_id, created_at}`. Written before Cloudflare
      is asked to create the adapter (with `adapter_id: nil`), updated with
      Cloudflare's id, deleted once the adapter is closed. `Octoroom.Janitor`
      closes adapters whose room or run is gone.

  The store holds no participant state: participants come back through
  their resume tokens.

  Configure with `config :octoroom, store: {module, opts}`. The default is
  `{Octoroom.Store.ETS, []}`.
  """

  @type store :: {module, keyword}
  @type table :: :rooms | :adapters

  @doc "Child spec for the store's process, if it has one."
  @callback child_spec(keyword) :: Supervisor.child_spec() | nil

  @callback get(keyword, table, key :: term) :: term | nil
  @callback put(keyword, table, key :: term, value :: term) :: :ok
  @callback delete(keyword, table, key :: term) :: :ok
  @callback all(keyword, table) :: [{term, term}]

  @doc "The configured store."
  @spec config() :: store
  def config, do: Application.get_env(:octoroom, :store, {Octoroom.Store.ETS, []})

  def get({mod, opts}, table, key), do: mod.get(opts, table, key)
  def put({mod, opts}, table, key, value), do: mod.put(opts, table, key, value)
  def delete({mod, opts}, table, key), do: mod.delete(opts, table, key)
  def all({mod, opts}, table), do: mod.all(opts, table)

  @doc false
  def now, do: System.system_time(:millisecond)
end
