# nim-libp2p-network-lab

Small, container-ready Nim nodes used to exercise `nim-libp2p` networks.

## Local use

Install the pinned Nim version and dependencies, then build an entrypoint:

```sh
nimble setup -y
nimble c -d:release src/network_lab/nodes/bootstrap/main.nim
nimble c -d:release src/network_lab/nodes/gossipsub/main.nim
nimble c -d:release src/network_lab/nodes/dummy/main.nim
```

Start the bootstrap node first and copy a logged address such as
`/ip4/127.0.0.1/tcp/9000/p2p/12D3...` into `BOOTSTRAP_ADDR` when starting a
GossipSub node.

## Container images

The single Dockerfile builds any node selected by `NODE`:

```sh
docker build --build-arg NODE=bootstrap -t network-lab/bootstrap -f docker/Dockerfile .
docker build --build-arg NODE=gossipsub -t network-lab/gossipsub -f docker/Dockerfile .
docker build --build-arg NODE=dummy -t network-lab/dummy -f docker/Dockerfile .
```

The GitHub Actions publication workflow runs for every push to `main`. It
rebuilds and pushes every node to GitHub Container Registry with both the
immutable commit SHA tag and the moving `main` tag.
