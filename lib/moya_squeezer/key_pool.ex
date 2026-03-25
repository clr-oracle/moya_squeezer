defmodule MoyaSqueezer.KeyPool do
  @moduledoc """
  Tracks known keys to support warmup and future smarter read/delete targeting.
  """

  use GenServer

  defstruct next_id: 1, keys: MapSet.new(), key_list: []

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name))
  end

  @spec next_new_key(pid() | atom()) :: String.t()
  def next_new_key(server), do: GenServer.call(server, :next_new_key)

  @spec random_existing_key(pid() | atom()) :: {:ok, String.t()} | :empty
  def random_existing_key(server), do: GenServer.call(server, :random_existing_key)

  @spec note_write_success(pid() | atom(), String.t()) :: :ok
  def note_write_success(server, key), do: GenServer.cast(server, {:write_success, key})

  @spec note_delete_success(pid() | atom(), String.t()) :: :ok
  def note_delete_success(server, key), do: GenServer.cast(server, {:delete_success, key})

  @impl true
  def init(:ok), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:next_new_key, _from, state) do
    key = "k#{state.next_id}"
    {:reply, key, %{state | next_id: state.next_id + 1}}
  end

  @impl true
  def handle_call(:random_existing_key, _from, state) do
    case state.key_list do
      [] -> {:reply, :empty, state}
      list -> {:reply, {:ok, Enum.at(list, :rand.uniform(length(list)) - 1)}, state}
    end
  end

  @impl true
  def handle_cast({:write_success, key}, state) do
    if MapSet.member?(state.keys, key) do
      {:noreply, state}
    else
      {:noreply, %{state | keys: MapSet.put(state.keys, key), key_list: [key | state.key_list]}}
    end
  end

  @impl true
  def handle_cast({:delete_success, key}, state) do
    if MapSet.member?(state.keys, key) do
      {:noreply,
       %{
         state
         | keys: MapSet.delete(state.keys, key),
           key_list: Enum.reject(state.key_list, &(&1 == key))
       }}
    else
      {:noreply, state}
    end
  end
end