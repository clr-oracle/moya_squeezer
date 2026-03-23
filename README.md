# moya_squeezer

Squeeze-testing framework for driving load against an existing database API.

## What it does

- Reads a TOML file that defines load dimensions.
- Starts one OTP process per configured logical connection.
- Generates `read`/`write`/`delete` traffic at the configured requests/second rate.
- Writes per-request metrics to a log file, buffered and flushed every 5ms.
- Prints per-second runtime stats (achieved RPS, error rate, p50/p95 latency).
- Handles Ctrl+C gracefully and prints a final summary report.

## Run

1. Install dependencies:

```bash
mix deps.get
```

2. Copy and edit the example config:

```bash
cp config/example.toml config/local.toml
```

3. Start load test:

```bash
mix squeezer.run config/local.toml
```

## Config fields (TOML)

- `connections`: Number of concurrent connection workers.
- `requests_per_second`: Total request throughput target across all workers.
- `read_ratio`, `write_ratio`, `delete_ratio`: Must sum to `1.0`.
- `payload_size`: Payload bytes used by write calls.
- `duration_seconds`: How long to run the test.
- `request_timeout_ms`: Adapter request timeout in ms (default `5000`).
- `max_retries`: Retry attempts for transport errors and HTTP 5xx (default `0`).
- `retry_backoff_ms`: Linear retry backoff base in ms (default `25`).
- `base_url`: API base URL (defaults to `http://localhost:9000`).
- `read_path`, `write_path`, `delete_path`: Endpoints (defaults `/read`, `/write`, `/delete`).
- `log_path`: Append-only metrics log path.

## Metrics log format

CSV columns:

`bucket_ms,request_type,started_at_ms,duration_us,response_code`

- `bucket_ms` is rounded down to 5ms buckets from `started_at_ms`.
- `response_code` is `0` when the request errors before receiving an HTTP response.

## Runtime console output

Per-second line:

`[sec] rps=... errors=... error_rate=...% p50=...ms p95=...ms`

Final line:

`[final] stop_reason=... total=... errors=... error_rate=...% avg=...ms p50=...ms p95=...ms`
