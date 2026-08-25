# syntax=docker/dockerfile:1.7

FROM golang:1.25.0-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/push-gateway ./cmd/push-gateway

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/push-gateway /push-gateway
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/push-gateway"]
