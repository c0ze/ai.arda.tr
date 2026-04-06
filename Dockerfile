##
## Stage 1: Build the Lustre frontend bundle.
##
## lustre_dev_tools downloads Bun on first run, so we need a writeable
## $HOME and network access during the build.
##
FROM ghcr.io/gleam-lang/gleam:v1.15.2-erlang-alpine AS frontend

WORKDIR /frontend
RUN apk add --no-cache bash libstdc++

# Cache deps separately from the source tree.
COPY frontend/gleam.toml frontend/manifest.toml* ./
RUN gleam deps download

# Source + static assets the build step reads/copies.
COPY frontend/src ./src
COPY public /public

# Emit the minified bundle + generated index.html into /public so the
# backend can serve it at runtime.
RUN gleam run -m lustre/dev build --minify --outdir=/public

##
## Stage 2: Build the Gleam backend as an Erlang release.
##
FROM ghcr.io/gleam-lang/gleam:v1.15.2-erlang-alpine AS builder

WORKDIR /build

# Cache dependencies separately from the source tree.
COPY gleam.toml manifest.toml* ./
RUN gleam deps download

# Copy the application source.
COPY src ./src
COPY test ./test

# Fetch the resume JSON at build time so the runtime image does not need
# outbound access to GitHub at boot.
RUN gleam run -- fetch

# Build a self-contained Erlang release tree under /build/build/erlang-shipment
RUN gleam export erlang-shipment

##
## Stage 3: Minimal runtime image.
##
FROM erlang:28-alpine

WORKDIR /app

# Copy the Gleam/Erlang shipment.
COPY --from=builder /build/build/erlang-shipment /app

# Resume data fetched at build time.
COPY --from=builder /build/data /app/data

# Static frontend assets (including the Lustre-built bundle) served by
# wisp.serve_static.
COPY --from=frontend /public /app/public

# Optional job-requirements rider appended to the system prompt at startup.
COPY job_requirements.md /app/job_requirements.md

ENV PUBLIC_DIR=/app/public

# Cloud Run expects 8080 by default
EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh", "run"]
