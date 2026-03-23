defmodule MoyaSqueezer do
  @moduledoc """
  Entry point helpers for running squeeze tests.
  """

  alias MoyaSqueezer.Runner

  @spec run(String.t()) :: :ok | {:error, term()}
  def run(config_path), do: Runner.run_from_file(config_path)
end
