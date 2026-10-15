# syntax=docker/dockerfile:1
ARG NIM_VERSION=2.2.10
ARG NIMBLE_VERSION=0.24.1

FROM nimlang/nim:${NIM_VERSION} AS build
ARG NODE
ARG NIMBLE_VERSION
ARG LIBP2P_REPOSITORY=https://github.com/vacp2p/nim-libp2p.git
ARG LIBP2P_REF=master

WORKDIR /app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      build-essential ca-certificates curl git libssl-dev pkg-config \
    && curl --fail --location --retry 3 \
      --output /tmp/nimble.tar.gz \
      "https://github.com/nim-lang/nimble/releases/download/v${NIMBLE_VERSION}/nimble-linux_x64.tar.gz" \
    && tar --extract --gzip --file /tmp/nimble.tar.gz --directory /usr/local/bin \
    && chmod +x /usr/local/bin/nimble \
    && /usr/local/bin/nimble --version \
    && rm /tmp/nimble.tar.gz \
    && rm -rf /var/lib/apt/lists/*

COPY . .

# Docker images use the current nim-libp2p master branch.
RUN test -n "$NODE" \
    && test -f "src/network_lab/nodes/${NODE}/main.nim" \
    && git clone --depth 1 --branch "$LIBP2P_REF" "$LIBP2P_REPOSITORY" /opt/nim-libp2p \
    && cd /opt/nim-libp2p && nimble develop -y \
    && cd /app \
    && nimble setup -y \
    && nim c -d:release --threads:on \
      --out:/out/network-node "src/network_lab/nodes/${NODE}/main.nim"

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/network-node /usr/local/bin/network-node

USER 65532:65532
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/network-node"]
