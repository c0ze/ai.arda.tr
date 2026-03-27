# Stage 1: Builder
FROM golang:1.26.1-alpine AS builder
WORKDIR /app

# Cache dependencies separately from the source tree.
COPY go.mod go.sum ./
RUN go mod download

# Copy the application source.
COPY . .

# Fetch resume data
RUN go run main.go -fetch

# Build Binary
# CGO_ENABLED=0 ensures a static binary
RUN CGO_ENABLED=0 GOOS=linux go build -o server main.go

# Stage 2: Runtime
FROM gcr.io/distroless/static-debian12
WORKDIR /

# Copy Binary and Static Assets
COPY --from=builder /app/server /server
COPY --from=builder /app/public /public
COPY --from=builder /app/data /data
COPY --from=builder /app/job_requirements.md /job_requirements.md

# Cloud Run expects 8080 by default
EXPOSE 8080

ENTRYPOINT ["/server"]
