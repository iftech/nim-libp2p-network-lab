# syntax=docker/dockerfile:1
ARG NIM_VERSION=2.2.10

FROM nimlang/nim:${NIM_VERSION} AS build
ARG NODE

WORKDIR /app

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      build-essential ca-certificates git libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

COPY . .

RUN test -n "$NODE" \
    && test -f "src/network_lab/nodes/${NODE}/main.nim" \
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
