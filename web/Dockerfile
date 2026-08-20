# cgc_2046 web 生产镜像（Next.js standalone）
# 构建上下文必须是 web/ 目录：docker build -f Dockerfile .
# 版本与 CI 对齐：Node 24 / pnpm 10.28.2

# ── deps: 拉依赖（pnpm-lock 不变时全量缓存）───────────────────
FROM node:24-slim AS deps
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile --prod=false

# ── build: next build（standalone 产物）───────────────────────
FROM node:24-slim AS build
WORKDIR /app
RUN corepack enable
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# NEXT_PUBLIC_* 是构建时内联（#254）：build 前必须注入，运行时改无效
# BACKEND_URL 同为构建期消费（rewrites destination，#213 AC1 fail-fast）：缺注入 build 即红
ARG NEXT_PUBLIC_WEB_BASE_URL
ENV NEXT_PUBLIC_WEB_BASE_URL=$NEXT_PUBLIC_WEB_BASE_URL
ARG BACKEND_URL
ENV BACKEND_URL=$BACKEND_URL
RUN pnpm build

# ── runtime: 仅 standalone server + static 产物 ───────────────
FROM node:24-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
RUN groupadd -r app && useradd -r -g app app
COPY --from=build --chown=app:app /app/.next/standalone ./
COPY --from=build --chown=app:app /app/.next/static ./.next/static
COPY --from=build --chown=app:app /app/public ./public
USER app
EXPOSE 3000
CMD ["node", "server.js"]
