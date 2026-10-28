# syntax=docker/dockerfile:1
ARG NIM_VERSION=2.2.12
ARG NIMBLE_VERSION=0.24.1

FROM nimlang/nim:${NIM_VERSION} AS build
ARG NIMBLE_VERSION
ARG LIBP2P_REPOSITORY=https://github.com/iftech/nim-libp2p.git
ARG LIBP2P_REF=master
ARG LIBP2P_CACHE_BUSTER=local

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

# Docker images use the current nim-libp2p master branch.
RUN test -n "$LIBP2P_CACHE_BUSTER" \
    && git clone --depth 1 --branch "$LIBP2P_REF" "$LIBP2P_REPOSITORY" /opt/nim-libp2p \
    && cd /opt/nim-libp2p \
    && nimble --useSystemNim setup -y \
    && grep -F /opt/nim-libp2p nimble.paths \
    && cp nimble.paths /app/nimble.paths \
    && printf '%s\n' '--path:"/app/src"' >> /app/nimble.paths

COPY . .

ARG NODE
RUN test -n "$NODE" \
    && test -f "src/network_lab/nodes/${NODE}/main.nim" \
    && nim c -d:release --threads:on --path:/opt/nim-libp2p \
      -d:Libp2pRevision="$(git -C /opt/nim-libp2p rev-parse HEAD)" \
      --out:/out/network-node "src/network_lab/nodes/${NODE}/main.nim"

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/network-node /usr/local/bin/network-node

USER 65532:65532
EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/network-node"]
