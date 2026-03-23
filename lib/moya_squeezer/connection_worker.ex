defmodule MoyaSqueezer.ConnectionWorker do
  @moduledoc """
  Represents one logical client connection that continuously emits load.
  """

  use GenServer

  @tick_ms 10

  defstruct [
    :id,
    :adapter,
    :adapter_opts,
    :logger,
    :stats_collector,
    :payload_size,
    :reqs_per_sec,
    :read_ratio,
    :write_ratio,
    :delete_ratio,
    token_balance: 0.0
  ]

  @type options :: [
          id: pos_integer(),
          adapter: module(),
          adapter_opts: map(),
          logger: pid() | atom(),
          stats_collector: pid() | atom(),
          payload_size: pos_integer(),
          reqs_per_sec: float(),
          read_ratio: float(),
          write_ratio: float(),
          delete_ratio: float()
        ]

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      adapter: Keyword.fetch!(opts, :adapter),
      adapter_opts: Keyword.fetch!(opts, :adapter_opts),
      logger: Keyword.fetch!(opts, :logger),
      stats_collector: Keyword.fetch!(opts, :stats_collector),
      payload_size: Keyword.fetch!(opts, :payload_size),
      reqs_per_sec: Keyword.fetch!(opts, :reqs_per_sec),
      read_ratio: Keyword.fetch!(opts, :read_ratio),
      write_ratio: Keyword.fetch!(opts, :write_ratio),
      delete_ratio: Keyword.fetch!(opts, :delete_ratio)
    }

    Process.send_after(self(), :tick, @tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    token_balance = state.token_balance + state.reqs_per_sec * (@tick_ms / 1000)
    requests_to_send = trunc(token_balance)
    remaining = token_balance - requests_to_send

    if requests_to_send > 0 do
      Enum.each(1..requests_to_send, fn _ -> send_one_request(state) end)
    end

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | token_balance: remaining}}
  end

  defp send_one_request(state) do
    request_type = choose_request_type(state)
    started_at_ms = System.system_time(:millisecond)
    monotonic_start = System.monotonic_time(:microsecond)

    response_code =
      case state.adapter.request(request_type, state.payload_size, state.adapter_opts) do
        {:ok, status} -> status
        {:error, _reason} -> 0
      end

    duration_us = System.monotonic_time(:microsecond) - monotonic_start

    MoyaSqueezer.MetricsLogger.log(state.logger, %{
      request_type: request_type,
      started_at_ms: started_at_ms,
      duration_us: duration_us,
      response_code: response_code
    })

    MoyaSqueezer.StatsCollector.record(state.stats_collector, %{
      request_type: request_type,
      started_at_ms: started_at_ms,
      duration_us: duration_us,
      response_code: response_code
    })
  end

  defp choose_request_type(state) do
    p = :rand.uniform()

    cond do
      p <= state.read_ratio ->
        :read

      p <= state.read_ratio + state.write_ratio ->
        :write

      true ->
        :delete
    end
  end
end
