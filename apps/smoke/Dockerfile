# syntax=docker/dockerfile:1
# Phase 5.1a: first-party reference image. Both bases are pinned by
# digest (the tag is informational); Dependabot proposes digest bumps.
# The build stage runs the unit tests, so an image never exists for code
# whose tests fail.
FROM golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
ARG VERSION=dev
RUN go vet ./... \
 && CGO_ENABLED=0 go test ./... \
 && CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/smoke .

# Static, shell-less, non-root (UID 65532 = the chart's runAsUser).
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/smoke /smoke
USER 65532:65532
EXPOSE 9898
ENTRYPOINT ["/smoke"]
