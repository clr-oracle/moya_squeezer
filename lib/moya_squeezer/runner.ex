defmodule MoyaSqueezer.Runner do
  @moduledoc """
  Main routine that runs a squeeze test from TOML configuration.
  """

  alias MoyaSqueezer.Config
  alias MoyaSqueezer.ConnectionWorker
  alias MoyaSqueezer.MetricsLogger
  alias MoyaSqueezer.StatsCollector

  @spec run_from_file(String.t()) :: :ok | {:error, term()}
  def run_from_file(path) do
    with {:ok, config} <- Config.from_toml_file(path) do
      run(config)
    end
  end

  @spec run(Config.t()) :: :ok
  def run(config) do
    adapter =
      Application.get_env(:moya_squeezer, :load_adapter, MoyaSqueezer.Adapters.HttpAdapter)

    requests_per_worker = config.requests_per_second / config.connections

    logger_name = :"metrics_logger_#{System.unique_integer([:positive])}"
    stats_name = :"stats_collector_#{System.unique_integer([:positive])}"

    {:ok, stats_collector} = StatsCollector.start_link(name: stats_name)

    children =
      [
        {MetricsLogger, name: logger_name, log_path: config.log_path}
      ] ++
        worker_children(config, adapter, logger_name, stats_name, requests_per_worker)

    {:ok, supervisor} =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        name: :"run_sup_#{System.unique_integer()}"
      )

    signal_setup = install_signal_handlers()
    stop_reason = wait_for_duration_or_signal(config.duration_seconds * 1_000)

    if match?({:signal, _}, stop_reason) do
      IO.puts("Signal received, stopping load run gracefully...")
    end

    :ok = Supervisor.stop(supervisor, :normal, 10_000)
    restore_signal_handlers(signal_setup)

    report = StatsCollector.final_report(stats_collector)
    print_final_report(report, stop_reason)
    GenServer.stop(stats_collector, :normal, 5_000)

    :ok
  end

  defp worker_children(config, adapter, logger_name, stats_name, requests_per_worker) do
    adapter_opts = %{
      base_url: config.base_url,
      request_timeout_ms: config.request_timeout_ms,
      max_retries: config.max_retries,
      retry_backoff_ms: config.retry_backoff_ms,
      read_path: config.read_path,
      write_path: config.write_path,
      delete_path: config.delete_path
    }

    Enum.map(1..config.connections, fn id ->
      %{
        id: {:connection_worker, id},
        start:
          {ConnectionWorker, :start_link,
           [
             [
               id: id,
               adapter: adapter,
               adapter_opts: adapter_opts,
               logger: logger_name,
               stats_collector: stats_name,
               payload_size: config.payload_size,
               reqs_per_sec: requests_per_worker,
               read_ratio: config.read_ratio,
               write_ratio: config.write_ratio,
               delete_ratio: config.delete_ratio
             ]
           ]}
      }
    end)
  end

  defp wait_for_duration_or_signal(duration_ms) do
    receive do
      {:signal, :sigint} -> {:signal, :sigint}
      {:signal, :sigterm} -> {:signal, :sigterm}
    after
      duration_ms -> :duration_elapsed
    end
  end

  defp install_signal_handlers do
    try do
      %{
        sigint: :os.set_signal(:sigint, :handle),
        sigterm: :os.set_signal(:sigterm, :handle)
      }
    rescue
      _ -> nil
    end
  end

  defp restore_signal_handlers(nil), do: :ok

  defp restore_signal_handlers(signal_setup) do
    :os.set_signal(:sigint, signal_setup.sigint)
    :os.set_signal(:sigterm, signal_setup.sigterm)
    :ok
  end

  defp print_final_report(report, stop_reason) do
    stop_label =
      case stop_reason do
        :duration_elapsed -> "duration_elapsed"
        {:signal, sig} -> Atom.to_string(sig)
      end

    IO.puts(
      "[final] stop_reason=#{stop_label} " <>
        "total=#{report.total_requests} errors=#{report.total_errors} " <>
        "error_rate=#{Float.round(report.error_rate_pct, 2)}% " <>
        "avg=#{Float.round(report.avg_latency_ms, 2)}ms " <>
        "p50=#{Float.round(report.p50_latency_ms, 2)}ms " <>
        "p95=#{Float.round(report.p95_latency_ms, 2)}ms"
    )
  end
end
