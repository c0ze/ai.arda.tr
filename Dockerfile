# Stage 1: Builder
FROM golang:1.23-alpine AS builder
WORKDIR /app

# Copy all files including go.mod and main.go
COPY . .

# Resolve dependencies (since we couldn't run go get locally)
RUN go mod tidy

# Build Binary
# CGO_ENABLED=0 ensures a static binary
RUN CGO_ENABLED=0 GOOS=linux go build -o server main.go

# Stage 2: Runtime
FROM gcr.io/distroless/static-debian12
WORKDIR /

# Copy Binary and Static Assets
COPY --from=builder /app/server /server
COPY --from=builder /app/public /public

# Cloud Run expects 8080 by default
EXPOSE 8080

ENTRYPOINT ["/server"]