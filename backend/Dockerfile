# cgc_2046 backend 生产镜像（Elixir release）
# 版本与 .github/workflows/ci.yml 完全对齐：Elixir 1.20 / OTP 29
# 构建上下文必须是 repo 根目录（COPY backend/…）：docker build -f backend/Dockerfile .

# ── deps: 拉取并编译依赖（mix.lock 不变时此层全量缓存）──────────
FROM hexpm/elixir:1.20.0-erlang-29.0-debian-bookworm-20260610-slim AS deps
WORKDIR /app
RUN apt-get update -y && apt-get install -y --no-install-recommends git ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*
COPY backend/mix.exs backend/mix.lock ./
RUN mix local.hex --force && mix local.rebar --force \
    && mix deps.get --only prod && mix deps.compile

# ── build: 编译 release（MIX_ENV=prod，无 dev/test 依赖）─────────
FROM deps AS build
COPY backend/ .
ENV MIX_ENV=prod
RUN mix compile && mix release

# ── runtime: 仅含 release 与运行时依赖，无源码无编译器───────────
FROM debian:bookworm-slim AS runtime
RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libtinfo6 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/sh app
WORKDIR /app
COPY --from=build --chown=app:app /app/_build/prod/rel/cgc_2046 ./
USER app
ENV HOME=/app PHX_SERVER=true
# PORT 由 Kamal env 注入（默认 4000）；全部密钥运行时注入，绝不进镜像
EXPOSE 4000
CMD ["/app/bin/cgc_2046", "start"]
