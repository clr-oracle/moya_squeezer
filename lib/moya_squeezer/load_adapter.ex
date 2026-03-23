defmodule MoyaSqueezer.LoadAdapter do
  @moduledoc """
  Adapter contract for sending test traffic to the target database API.
  """

  @type request_type :: :read | :write | :delete

  @callback request(request_type(), payload_size :: pos_integer(), adapter_opts :: map()) ::
              {:ok, status_code :: integer()} | {:error, term()}
end
