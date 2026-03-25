FROM hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20240812-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get

COPY lib ./lib
COPY scripts ./scripts

RUN mix compile

CMD ["mix", "squeezer.run", "config/docker.toml"]
