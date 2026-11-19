# Phase 6.3b (ADR-0023): apps/notes, the reference application's data
# service. Both bases are pinned by digest (the tag is informational);
# Dependabot proposes digest bumps. The build stage installs exactly the
# hash-pinned wheels of requirements.txt and runs the unit tests, so an
# image never exists for code whose tests fail.
#
# The dependencies are pure Python, so the build stage runs on the
# builder's own platform and the result is the same for linux/amd64 and
# linux/arm64; the runtime stage only copies files.
FROM --platform=$BUILDPLATFORM python:3.13-slim-trixie@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90 AS build
WORKDIR /src
ENV PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt ./
RUN pip install --require-hashes --no-deps --only-binary=:all: --target /deps -r requirements.txt
COPY *.py ./
RUN PYTHONPATH=/deps python -m unittest -q \
 && PYTHONPATH=/deps python -c "import pg8000.native, store" \
 && rm test_app.py

# Shell-less, non-root (UID 65532 = the chart's runAsUser). Debian 13's
# distroless Python (3.13): the Debian 12 one carried an unpatched 3.11.2
# and about thirty fixable HIGH findings, which the scan gate refused.
FROM gcr.io/distroless/python3-debian13:nonroot@sha256:6c4cb3bfa4b555429dd19541796a6ba6b30c84675b460bd0bd5072f7d5bdae71
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/IngMatrix-PGB/eks-gitops-platform-project" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.description="apps/notes - the reference application's data service"
ENV PYTHONPATH=/app/deps PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 VERSION=${VERSION}
COPY --from=build /deps /app/deps
COPY --from=build /src/*.py /app/
USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["python3", "/app/app.py"]
