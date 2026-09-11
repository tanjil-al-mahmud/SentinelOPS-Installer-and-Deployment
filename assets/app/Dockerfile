# Sentinel Ops frontend - production image.
#
# This file belongs in the Sentinel Ops application repository. The installer
# only supplies it when the repository does not carry one of its own.
#
# Stage 1 builds the React/Vite bundle, stage 2 serves the static output from
# nginx. The runtime image contains no Node.js, no source and no node_modules.

# docker - npm ci and the build run inside this image (default; the server
#          needs no Node.js toolchain).
# host   - the build already ran on the host and dist/ is copied in as-is.
ARG BUILD_MODE=docker

# ---------------------------------------------------------------------------
# Stage 1a: build inside Docker
# ---------------------------------------------------------------------------
FROM node:20-alpine AS builder-docker

WORKDIR /app

# Dependencies are installed from the lockfile first so that Docker can reuse
# this layer whenever only application source changed.
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

COPY . .

# Vite inlines VITE_* variables at build time, so they must be present here.
# Only the publishable (anon) key is passed in - it is public by design and is
# shipped to the browser. The service-role key must never appear in a build.
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_PUBLISHABLE_KEY
ARG VITE_SUPABASE_PROJECT_ID=local
ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_PUBLISHABLE_KEY=$VITE_SUPABASE_PUBLISHABLE_KEY \
    VITE_SUPABASE_PROJECT_ID=$VITE_SUPABASE_PROJECT_ID \
    NODE_ENV=production

RUN npm run build

# Vite writes to dist/ by default; normalise other common output directories so
# the runtime stage always finds the bundle at /out.
RUN if   [ -d dist ];  then cp -r dist /out; \
    elif [ -d build ]; then cp -r build /out; \
    else echo "Build produced neither dist/ nor build/" >&2; exit 1; fi

# ---------------------------------------------------------------------------
# Stage 1b: reuse a build produced on the host
# ---------------------------------------------------------------------------
FROM alpine:3.20 AS builder-host
WORKDIR /
COPY dist /out

# Select the stage named by BUILD_MODE. Only the selected stage is built.
FROM builder-${BUILD_MODE} AS builder

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM nginx:1.27-alpine AS runtime

ARG APP_PORT=3000
ENV APP_PORT=$APP_PORT

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /out /usr/share/nginx/html

# The port is templated so the installer can move the app off 3000 without
# editing this file.
RUN sed -i "s/__APP_PORT__/${APP_PORT}/g" /etc/nginx/conf.d/default.conf

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- "http://127.0.0.1:${APP_PORT}/healthz" >/dev/null 2>&1 || exit 1

CMD ["nginx", "-g", "daemon off;"]
