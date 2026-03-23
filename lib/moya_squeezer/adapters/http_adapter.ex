defmodule MoyaSqueezer.Adapters.HttpAdapter do
  @moduledoc """
  Default adapter that sends read/write/delete calls over HTTP.
  """

  @behaviour MoyaSqueezer.LoadAdapter

  @impl true
  def request(type, payload_size, adapter_opts) do
    base_url = Map.fetch!(adapter_opts, :base_url)
    request_id = System.unique_integer([:positive, :monotonic])
    payload = payload(payload_size)
    timeout_ms = Map.get(adapter_opts, :request_timeout_ms, 5_000)
    max_retries = Map.get(adapter_opts, :max_retries, 0)
    retry_backoff_ms = Map.get(adapter_opts, :retry_backoff_ms, 25)

    {method, url, body, headers} =
      case type do
        :read ->
          path = Map.get(adapter_opts, :read_path, "/read")
          {:get, "#{base_url}#{path}?id=#{request_id}", "", []}

        :write ->
          path = Map.get(adapter_opts, :write_path, "/write")
          {:post, "#{base_url}#{path}", payload, [{"content-type", "text/plain"}]}

        :delete ->
          path = Map.get(adapter_opts, :delete_path, "/delete")
          {:delete, "#{base_url}#{path}?id=#{request_id}", "", []}
      end

    do_request(method, url, headers, body, timeout_ms, max_retries, retry_backoff_ms, 0)
  end

  defp do_request(method, url, headers, body, timeout_ms, max_retries, retry_backoff_ms, attempt) do
    result =
      method
      |> Finch.build(url, headers, body)
      |> Finch.request(MoyaSqueezerFinch, receive_timeout: timeout_ms)

    case result do
      {:ok, %Finch.Response{status: status}} when status >= 500 and attempt < max_retries ->
        backoff_sleep(retry_backoff_ms, attempt)

        do_request(
          method,
          url,
          headers,
          body,
          timeout_ms,
          max_retries,
          retry_backoff_ms,
          attempt + 1
        )

      {:ok, %Finch.Response{status: status}} ->
        {:ok, status}

      {:error, _reason} when attempt < max_retries ->
        backoff_sleep(retry_backoff_ms, attempt)

        do_request(
          method,
          url,
          headers,
          body,
          timeout_ms,
          max_retries,
          retry_backoff_ms,
          attempt + 1
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backoff_sleep(backoff_ms, attempt) do
    Process.sleep(backoff_ms * (attempt + 1))
  end

  defp payload(size) do
    :binary.copy("x", max(size, 1))
  end
end
