# cgc_2046 backend 生产镜像（Elixir release）
# 构建上下文必须是 repo 根目录（COPY backend/…）：docker build -f backend/Dockerfile .
#
# deps 层外置为预构建基础镜像（backend/Dockerfile.deps，tag=mix.lock 哈希），
# CI 经 --build-arg BACKEND_DEPS_IMAGE 注入；本地构建先自建 deps 镜像：
#   docker build -f backend/Dockerfile.deps -t cgc2046-backend-deps:dev .
#   docker build --build-arg BACKEND_DEPS_IMAGE=cgc2046-backend-deps:dev -f backend/Dockerfile .
ARG BACKEND_DEPS_IMAGE

# ── build: 在 deps 镜像（依赖已编译）之上编译 release（MIX_ENV=prod，无 dev/test 依赖）──
FROM ${BACKEND_DEPS_IMAGE} AS build
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
# ENTRYPOINT 固定启动器：docker run IMAGE eval/migrate 等子命令直接分发，
# 不会覆写丢失启动器（pre-deploy 钩子依赖此形态）
ENTRYPOINT ["/app/bin/cgc_2046"]
CMD ["start"]
