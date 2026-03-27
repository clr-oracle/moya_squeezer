defmodule MoyaSqueezer.LoadAdapter do
  @moduledoc """
  Adapter contract for sending test traffic to the target database API.
  """

  @type request_type :: :read | :write | :delete

  @callback request(
              request_type(),
              payload_size :: pos_integer(),
              adapter_opts :: map(),
              key :: String.t() | nil
            ) ::
              {:ok, status_code :: integer(), db_latency_us :: non_neg_integer()} |
                {:error, term(), db_latency_us :: non_neg_integer()}
end
