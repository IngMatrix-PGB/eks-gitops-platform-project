# Phase 5.1a: first-party reference image. Both bases are pinned by
# digest (the tag is informational); Dependabot proposes digest bumps.
# The build stage runs the unit tests, so an image never exists for code
# whose tests fail.
#
# Phase 5.1b: multi-platform (linux/amd64 for CI and EKS, linux/arm64 for
# the kind lab on Apple silicon) without emulation - the build stage runs
# on the builder's own platform and Go cross-compiles for TARGETARCH; the
# runtime stage only copies the binary.
FROM --platform=$BUILDPLATFORM golang:1.27.4-bookworm@sha256:4fa7c968ba93f1635670522dbb01a2c78150443e1385746924566079f36570ea AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
ARG VERSION=dev
ARG TARGETOS=linux
ARG TARGETARCH
RUN go vet ./... \
 && CGO_ENABLED=0 go test ./... \
 && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/smoke .

# Static, shell-less, non-root (UID 65532 = the chart's runAsUser).
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/IngMatrix-PGB/eks-gitops-platform-project" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.description="apps/smoke - the platform's first-party reference workload"
COPY --from=build /out/smoke /smoke
USER 65532:65532
EXPOSE 9898
ENTRYPOINT ["/smoke"]
