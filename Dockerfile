##
## Stage 1: Build the Erlang release using the official Gleam image.
##
## The Gleam image ships with Erlang/OTP + rebar3 + gleam preinstalled,
## so we only need to resolve deps and run `gleam export erlang-shipment`.
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
## Stage 2: Minimal runtime image.
##
## We need a runtime that has Erlang available. Distroless does not ship
## Erlang, so we use erlang-alpine (tiny, ~60MB) and copy only the shipment.
##
FROM erlang:27-alpine

WORKDIR /app

# Copy the Gleam/Erlang shipment.
COPY --from=builder /build/build/erlang-shipment /app

# Resume data fetched at build time.
COPY --from=builder /build/data /app/data

# Static frontend assets (served by wisp.serve_static).
COPY public /app/public

# Optional job-requirements rider appended to the system prompt at startup.
COPY job_requirements.md /app/job_requirements.md

ENV PUBLIC_DIR=/app/public

# Cloud Run expects 8080 by default
EXPOSE 8080

ENTRYPOINT ["/app/entrypoint.sh", "run"]
