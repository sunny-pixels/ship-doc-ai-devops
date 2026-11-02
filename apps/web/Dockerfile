# syntax=docker/dockerfile:1

FROM node:22-slim AS base
WORKDIR /app
# Pin pnpm (matches mise.toml): package.json has no packageManager field, so
# corepack would otherwise fetch the newest major, which changes install rules.
RUN corepack enable && corepack prepare pnpm@10.11.0 --activate

FROM base AS deps
COPY package.json pnpm-lock.yaml* ./
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile || pnpm install

FROM base AS builder
# NEXT_PUBLIC_* values are inlined into the client bundle at build time, so
# the API URL has to be a build arg, not a runtime env var.
ARG NEXT_PUBLIC_API_BASE_URL=http://localhost:8000/
ENV NEXT_PUBLIC_API_BASE_URL=$NEXT_PUBLIC_API_BASE_URL \
    NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN pnpm build

FROM node:22-slim AS runtime
WORKDIR /app
# HOSTNAME must be overridden: Docker sets it to the container id, and the
# standalone server binds to whatever HOSTNAME resolves to.
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    HOSTNAME=0.0.0.0 \
    PORT=3000
COPY --from=builder --chown=node:node /app/public ./public
COPY --from=builder --chown=node:node /app/.next/standalone ./
COPY --from=builder --chown=node:node /app/.next/static ./.next/static

# The node image ships an unprivileged "node" user (uid 1000).
USER node

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:3000/').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]

CMD ["node", "server.js"]
