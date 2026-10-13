# nim-libp2p-network-lab

Small, container-ready Nim nodes used to exercise `nim-libp2p` networks.

## Nodes

- `dummy` is deliberately independent of `nim-libp2p`. It exits successfully
  most of the time and exits with a random non-zero status according to
  `FAILURE_PERCENT` (default: `10`). It is useful for deployment and restart
  policy tests.
- `bootstrap` is a TCP/Noise/Yamux `nim-libp2p` peer that also participates in
  the configured GossipSub topic. Its complete `/p2p/...` multiaddress is
  logged at startup and is the bootstrap address for the other peers.
- `gossipsub` is a TCP/Noise/Yamux GossipSub peer. It dials `BOOTSTRAP_ADDR`
  and subscribes to the configured topic. It exits with status `1` if it has
  not observed another GossipSub peer on that topic within two minutes.

The bootstrap peer is itself a GossipSub peer, so one bootstrap plus one or
more `gossipsub` containers form a working GossipSub network. In a deployed
environment give the bootstrap a stable identity and distribute its full
multiaddress (including `/p2p/<peer-id>`) through deployment configuration.

## Configuration

| Variable | Nodes | Default | Meaning |
| --- | --- | --- | --- |
| `FAILURE_PERCENT` | dummy | `10` | Chance, from 0 to 100, that dummy exits unsuccessfully. |
| `LISTEN_ADDR` | bootstrap, gossipsub | `/ip4/0.0.0.0/tcp/9000` | Libp2p listen multiaddress. |
| `ANNOUNCE_ADDR` | bootstrap, gossipsub | unset | Public or cluster-reachable address to advertise, without `/p2p/<peer-id>`. |
| `PRIVATE_KEY` | bootstrap, gossipsub | random per start | Hex-encoded libp2p private key. Set it for a stable peer ID. |
| `GOSSIPSUB_TOPIC` | bootstrap, gossipsub | `network-lab` | Shared GossipSub topic. |
| `BOOTSTRAP_ADDR` | gossipsub | required | Full bootstrap multiaddress, including peer ID. |
| `SELF_CHECK_TIMEOUT_SECS` | gossipsub | `120` | Maximum wait for a remote GossipSub peer. |

All long-running nodes stop cleanly on `SIGINT` or `SIGTERM`.

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

The GitHub Actions publication workflow runs for every push to `master`. It
rebuilds and pushes every node to GitHub Container Registry with both the
immutable commit SHA tag and the moving `master` tag.
