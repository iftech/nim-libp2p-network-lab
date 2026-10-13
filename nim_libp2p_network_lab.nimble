mode = ScriptMode.Verbose

packageName = "nim_libp2p_network_lab"
version = "0.1.0"
author = "IFTech"
description = "Container-ready nim-libp2p network lab nodes"
license = "MIT"
srcDir = "src"

requires(
  "nim == 2.2.10", "libp2p >= 2.4.0", "chronicles >= 0.12.3", "chronos >= 4.2.2",
  "results >= 0.5.1", "stew >= 0.5.2",
)

task test, "Run unit and integration tests":
  exec "nim c -r tests/test_all.nim"

task buildNodes, "Build all node binaries":
  mkDir "build"
  exec "nim c -d:release --out:build/dummy src/network_lab/nodes/dummy/main.nim"
  exec "nim c -d:release --out:build/bootstrap src/network_lab/nodes/bootstrap/main.nim"
  exec "nim c -d:release --out:build/gossipsub src/network_lab/nodes/gossipsub/main.nim"
