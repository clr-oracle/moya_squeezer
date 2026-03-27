defmodule MoyaSqueezer.ConfigTest do
  use ExUnit.Case, async: true

  alias MoyaSqueezer.Config

  test "from_map applies defaults for squeeze fields" do
    map = %{
      connections: 2,
      requests_per_second: 100,
      read_ratio: 0.7,
      write_ratio: 0.2,
      delete_ratio: 0.1,
      payload_size: 128,
      duration_seconds: 5
    }

    assert {:ok, config} = Config.from_map(map)
    assert config.start_requests_per_second == 100
    assert config.rps_step == 0
    assert config.step_interval_seconds == 5
    assert config.baseline_window_seconds == 10
    assert config.max_error_rate_pct == 1.0
  end

  test "from_map accepts explicit squeeze fields" do
    map = %{
      connections: 2,
      requests_per_second: 100,
      start_requests_per_second: 50,
      rps_step: 10,
      step_interval_seconds: 2,
      baseline_window_seconds: 3,
      max_error_rate_pct: 0.5,
      read_ratio: 0.7,
      write_ratio: 0.2,
      delete_ratio: 0.1,
      payload_size: 128,
      duration_seconds: 5
    }

    assert {:ok, config} = Config.from_map(map)
    assert config.start_requests_per_second == 50
    assert config.rps_step == 10
    assert config.step_interval_seconds == 2
    assert config.baseline_window_seconds == 3
    assert config.max_error_rate_pct == 0.5
  end
end
