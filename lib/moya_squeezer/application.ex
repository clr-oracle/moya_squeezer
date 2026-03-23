defmodule MoyaSqueezer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Finch, name: MoyaSqueezerFinch}
    ]

    opts = [strategy: :one_for_one, name: MoyaSqueezer.ApplicationSupervisor]
    Supervisor.start_link(children, opts)
  end
end
