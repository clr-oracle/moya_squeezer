defmodule Mix.Tasks.Squeezer.Run do
  @moduledoc """
  Runs the squeeze-test routine.

      mix squeezer.run path/to/config.toml
  """

  use Mix.Task

  @shortdoc "Run a squeeze test from TOML config"

  @impl true
  def run([config_path]) do
    Mix.Task.run("app.start")

    case MoyaSqueezer.run(config_path) do
      :ok ->
        Mix.shell().info("Squeeze test completed.")

      {:error, reason} ->
        Mix.raise("Squeeze test failed: #{reason}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix squeezer.run path/to/config.toml")
  end
end
