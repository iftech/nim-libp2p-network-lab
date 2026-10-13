mode = ScriptMode.Verbose

packageName = "nim_libp2p_network_lab"
version = "0.1.0"
author = "IFTech"
description = "Container-ready nim-libp2p network lab nodes"
license = "MIT"
srcDir = "src"

requires "nim == 2.2.10",
  "libp2p >= 2.4.0",
  "chronicles >= 0.12.3",
  "chronos >= 4.2.2"
