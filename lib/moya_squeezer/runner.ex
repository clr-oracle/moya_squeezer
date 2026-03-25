defmodule MoyaSqueezer.Runner do
  @moduledoc """
  Main routine that runs a squeeze test from TOML configuration.
  """

  alias MoyaSqueezer.Config
  alias MoyaSqueezer.ConnectionWorker
  alias MoyaSqueezer.KeyPool
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

    start_rps = config.start_requests_per_second
    start_rps_per_worker = start_rps / config.connections

    logger_name = :"metrics_logger_#{System.unique_integer([:positive])}"
    stats_name = :"stats_collector_#{System.unique_integer([:positive])}"
    key_pool_name = :"key_pool_#{System.unique_integer([:positive])}"

    {:ok, stats_collector} = StatsCollector.start_link(name: stats_name)
    {:ok, _key_pool} = KeyPool.start_link(name: key_pool_name)

    children = [
      {MetricsLogger, name: logger_name, log_path: config.log_path}
    ]

    {:ok, supervisor} =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        name: :"run_sup_#{System.unique_integer()}"
      )

    warmup_stop_reason =
      maybe_run_warmup(
        config,
        adapter,
        logger_name,
        stats_name,
        key_pool_name,
        start_rps_per_worker
      )

    if warmup_stop_reason == :warmup_interrupted do
      :ok = Supervisor.stop(supervisor, :normal, 10_000)
      GenServer.stop(stats_collector, :normal, 5_000)
      :ok
    else
      StatsCollector.reset(stats_collector)

      measured_sup =
        start_worker_supervisor(
          config,
          adapter,
          logger_name,
          stats_name,
          key_pool_name,
          start_rps_per_worker,
          :measured
        )

      signal_setup = install_signal_handlers()

      worker_pids = worker_pids(measured_sup)

      stop_reason =
        run_squeeze_control_loop(config, stats_collector, worker_pids, start_rps, config.duration_seconds)

      :ok = Supervisor.stop(measured_sup, :normal, 10_000)
      :ok = Supervisor.stop(supervisor, :normal, 10_000)
      restore_signal_handlers(signal_setup)

      report = StatsCollector.final_report(stats_collector)
      print_final_report(report, stop_reason)
      GenServer.stop(stats_collector, :normal, 5_000)

      :ok
    end
  end

  defp run_squeeze_control_loop(config, stats_collector, worker_pids, start_rps, duration_seconds) do
    started_at_ms = System.monotonic_time(:millisecond)
    deadline_ms = started_at_ms + duration_seconds * 1_000

    baseline_stop = wait_for_duration_or_signal(min(config.baseline_window_seconds * 1_000, deadline_ms - started_at_ms))

    case baseline_stop do
      {:signal, sig} ->
        {:signal, sig}

      :duration_elapsed ->
        now_ms = System.monotonic_time(:millisecond)

        if now_ms >= deadline_ms do
          :duration_elapsed
        else
          baseline_p90_ms = StatsCollector.percentile_ms(stats_collector, 0.90)

          IO.puts("[baseline] p90=#{Float.round(baseline_p90_ms, 2)}ms")

          ramp_loop(%{
            config: config,
            stats_collector: stats_collector,
            worker_pids: worker_pids,
            current_rps: start_rps,
            baseline_p90_ms: baseline_p90_ms,
            last_step_at_ms: now_ms,
            deadline_ms: deadline_ms
          })
        end
    end
  end

  defp ramp_loop(state) do
    remaining_ms = max(state.deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:signal, sig} ->
        {:signal, sig}
    after
      min(1_000, remaining_ms) ->
        now_ms = System.monotonic_time(:millisecond)

        cond do
          now_ms >= state.deadline_ms ->
            :duration_elapsed

          true ->
            snapshot = StatsCollector.window_snapshot(state.stats_collector)

            cond do
              snapshot.error_rate_pct > state.config.max_error_rate_pct ->
                :error_rate_exceeded

              snapshot.count > 0 and snapshot.p50_latency_ms > state.baseline_p90_ms ->
                :p50_exceeded_baseline_p90

              true ->
                {next_rps, next_step_ms} = maybe_step_rps(state, now_ms)

                ramp_loop(%{state | current_rps: next_rps, last_step_at_ms: next_step_ms})
            end
        end
    end
  end

  defp maybe_step_rps(state, now_ms) do
    step_interval_ms = state.config.step_interval_seconds * 1_000

    if state.config.rps_step > 0 and now_ms - state.last_step_at_ms >= step_interval_ms do
      next_rps = state.current_rps + state.config.rps_step
      set_worker_rates(state.worker_pids, next_rps / state.config.connections)
      IO.puts("[ramp] target_rps=#{next_rps}")
      {next_rps, now_ms}
    else
      {state.current_rps, state.last_step_at_ms}
    end
  end

  defp set_worker_rates(worker_pids, reqs_per_worker) do
    Enum.each(worker_pids, &ConnectionWorker.set_reqs_per_sec(&1, reqs_per_worker))
  end

  defp worker_pids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp start_worker_supervisor(
         config,
         adapter,
         logger_name,
         stats_name,
         key_pool_name,
         requests_per_worker,
         mode
       ) do
    children = worker_children(config, adapter, logger_name, stats_name, key_pool_name, requests_per_worker, mode)

    {:ok, supervisor} =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        name: :"worker_sup_#{System.unique_integer()}"
      )

    supervisor
  end

  defp maybe_run_warmup(config, _adapter, _logger_name, _stats_name, _key_pool_name, _requests_per_worker)
       when config.warmup_seconds <= 0,
       do: :no_warmup

  defp maybe_run_warmup(config, adapter, logger_name, stats_name, key_pool_name, requests_per_worker) do
    IO.puts("[warmup] seeding keys for #{config.warmup_seconds}s using write-only traffic...")

    warmup_sup =
      start_worker_supervisor(
        config,
        adapter,
        logger_name,
        stats_name,
        key_pool_name,
        requests_per_worker,
        :warmup
      )

    warmup_stop_reason = wait_for_duration_or_signal(config.warmup_seconds * 1_000)
    :ok = Supervisor.stop(warmup_sup, :normal, 10_000)

    case warmup_stop_reason do
      {:signal, _sig} ->
        IO.puts("Signal received during warmup, stopping run.")
        :warmup_interrupted

      :duration_elapsed ->
        IO.puts("[warmup] completed. starting measured phase...")
        :warmup_complete
    end
  end

  defp worker_children(config, adapter, logger_name, stats_name, key_pool_name, requests_per_worker, mode) do
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
               delete_ratio: config.delete_ratio,
               key_pool: key_pool_name,
               mode: mode
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
        :error_rate_exceeded -> "error_rate_exceeded"
        :p50_exceeded_baseline_p90 -> "p50_exceeded_baseline_p90"
        {:signal, sig} -> Atom.to_string(sig)
      end

    IO.puts(
      "[final] stop_reason=#{stop_label} " <>
        "total=#{report.total_requests} errors=#{report.total_errors} " <>
        "error_rate=#{Float.round(report.error_rate_pct, 2)}% " <>
        "avg=#{Float.round(report.avg_latency_ms, 2)}ms " <>
        "p50=#{Float.round(report.p50_latency_ms, 2)}ms " <>
        "p90=#{Float.round(report.p90_latency_ms, 2)}ms " <>
        "p95=#{Float.round(report.p95_latency_ms, 2)}ms"
    )
  end
end
