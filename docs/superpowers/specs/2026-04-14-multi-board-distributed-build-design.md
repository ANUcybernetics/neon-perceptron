# Multi-board distributed build (V2 testbed → V3 enabler)

## Goal

Split the running system across two Nerves devices connected by a wired LAN,
communicating via distributed Erlang and Phoenix.PubSub, so that:

1. The reTerminal DM (CM4) runs the trainer, touch input, web UI, and digital
   twin.
2. A second headless Raspberry Pi 4B drives all the physical TLC5947 LED
   chains via its own SPI buses.

The immediate target is a V2-equivalent build (4→3→3 pattern classifier) running
in this split topology, primarily as a testbed. Once proven, the same
architecture unlocks V3 (5×5 MNIST), which cannot fit its required SPI bus
count on a single board.

## Non-goals

- Changing the Trainer or Chain logic itself.
- Changing the V2 wiring layout.
- A multi-trainer or HA design --- if the trainer node is down, the
  installation is down.
- Supporting more than two nodes.

## Why this is feasible with small surface area

The current code is already cleanly decomposed along the right seam:

- `NeonPerceptron.Trainer` continuously trains and broadcasts a `NetworkState`
  on Phoenix.PubSub topic `"network_state"` every 33ms
  (`lib/neon_perceptron/trainer.ex`).
- `NeonPerceptron.Chain` GenServers subscribe to that topic
  (`lib/neon_perceptron/chain.ex:67`), render the slice of the network they
  represent, and push to SPI.
- `Phoenix.PubSub`'s default PG adapter broadcasts to all connected Erlang
  nodes transparently. Once two Nerves nodes are clustered, a `Chain` running
  on either node receives the same broadcasts with no code change.
- `application.ex` already reads a `:role` env (defaulting to `:trainer`) and
  has a `build_children/2` that branches on it, so the supervision split has a
  hook in place.

Therefore the change is *supervision gating + node clustering*, not a refactor
of the network or rendering code.

## Hardware topology

```
┌────────────────────────────────┐         ┌────────────────────────────┐
│ UI node  (reTerminal DM, CM4)  │         │ LED node  (RPi 4B headless)│
│ role: :trainer                 │         │ role: :led_driver          │
│ host:  nerves-ui.local         │         │ host:  nerves-leds.local   │
│                                │         │                            │
│  Trainer ─┐                    │         │  Chain :input_left ──► SPI1│
│  Touch    ├─► PubSub ══════════╪═════════╪═► Chain :main      ──► SPI0│
│  Phoenix ─┘                    │  dist   │                            │
│  DigitalTwin LV ←──────────────┘  Erlang │                            │
└────────────────────────────────┘         └────────────────────────────┘
            │                                          │
          eth0                                       eth0
            └────────► [small switch + WAN uplink] ◄───┘
                              │
                       venue router → internet (mDNS, NTP, OTA)
```

- Wired Ethernet only. WiFi is explicitly excluded for this installation.
- The switch's WAN uplink lets both boards reach the internet for OTA updates
  via `mix upload`, but the two Nerves nodes communicate over the local LAN
  segment.
- Both nodes get DHCP from the venue router and advertise via mDNS using the
  existing `mdns_lite` configuration in `config/target.exs`.

## V2 wiring (unchanged from current `chain_configs/0`)

Both chains live on the LED node. The wiring is identical to today's
`Builds.V2.chain_configs/0`:

| spidev    | Chain ID      | Chips | Contents                                     |
|-----------|---------------|-------|----------------------------------------------|
| spidev1.0 | `:input_left` | 2     | input[0], input[2]                           |
| spidev0.0 | `:main`       | 11    | input[1], input[3], hidden×6 (front+rear), output×3 |

No change to `lib/neon_perceptron/builds/v2.ex` is required for the wiring
itself --- only the host board changes. The build module still defines the
chains; the LED node starts them; the trainer node skips them.

## Software architecture

### Roles

Extend the existing `:role` Application env to three explicit values. Default
remains `:standalone` so all dev/host workflows and the existing single-board
setup continue to work unchanged.

| Role           | Trainer | Chains | Phoenix Endpoint | Touch | mix target use            |
|----------------|---------|--------|------------------|-------|---------------------------|
| `:standalone`  | yes     | yes    | yes              | yes   | host, single-board firmware |
| `:trainer`     | yes     | no     | yes              | yes   | UI node firmware (reTerminal DM) |
| `:led_driver`  | no      | yes    | no               | no    | LED node firmware (RPi 4B)       |

`:standalone` is the default, ensuring backwards compatibility with V1 and the
existing single-board V2.

### Supervision changes (`lib/neon_perceptron/application.ex`)

`build_children/2` is the only function that needs to change:

- `:trainer` role: start `Trainer` and `extra_children`, but skip `Chain`
  workers.
- `:led_driver` role: start `Chain` workers and `PubSub`, but skip `Trainer`,
  `Touch`, and the `Endpoint`.
- `:standalone`: current behaviour.

The current `phoenix_children/0` helper bundles `Phoenix.PubSub` with
`Endpoint`. Split this: `pubsub_children/0` (always started, on every role)
and `endpoint_children/0` (only `:standalone` and `:trainer`). PubSub is the
distribution mechanism --- both nodes must run it.

### Clustering

Add `libcluster` as a dependency. Configure two strategies:

- **`Cluster.Strategy.Epmd`** with a static node list for production firmware:
  `[:"neon_perceptron@nerves-ui.local", :"neon_perceptron@nerves-leds.local"]`.
  Static lists are simpler, more predictable, and require no service discovery.
- The `:standalone` role does not start libcluster (no peer to connect to).

The Erlang cookie is baked into firmware at build time. Both firmware images
must be built with the same cookie. A small `config/cookie.exs` (gitignored,
generated locally) feeds `:vm_args` for both targets.

Node names: `neon_perceptron@nerves-ui.local` and
`neon_perceptron@nerves-leds.local`. Configured via `vm.args.eex` in
`rel/`.

### Distributed PubSub

No code change. `Phoenix.PubSub` started under `phoenix_children/0` (renamed
to acknowledge that PubSub is needed in non-Phoenix roles too) uses the
default PG adapter, which broadcasts to all subscribers across all connected
nodes.

When the LED node connects, its `Chain` subscribers automatically receive
broadcasts from the trainer's `Trainer` process on the UI node.

### LED-side watchdog (optional, deferred)

If the trainer node disappears, `Chain` processes simply stop receiving
messages and hold their last frame indefinitely. For a public installation this
may be undesirable.

A future enhancement: each `Chain` tracks the timestamp of the last received
frame. If no frame for N seconds (configurable, default 5s), render a slow
breathing pulse or test pattern to indicate "system alive, no data".

This is **out of scope for the initial split**. We can add it once the split
itself is proven.

## Firmware & deployment

Two firmware artifacts from one repo:

| Firmware | MIX_TARGET | Nerves system    | Role         | Host name             |
|----------|-----------|------------------|--------------|-----------------------|
| UI       | rpi4      | reterminal_dm    | `:trainer`   | `nerves-ui.local`     |
| LED      | rpi4      | nerves_system_rpi4 | `:led_driver` | `nerves-leds.local` |

Build commands (suggested mix aliases or scripts):

```sh
# UI firmware (reTerminal DM)
NERVES_HOSTNAME=nerves-ui NERVES_ROLE=trainer \
  mise exec -- env MIX_TARGET=rpi4 MIX_ENV=prod mix firmware

# LED firmware (Pi 4B)
NERVES_HOSTNAME=nerves-leds NERVES_ROLE=led_driver \
  mise exec -- env MIX_TARGET=rpi4 MIX_ENV=prod mix firmware
```

`mix.exs` selects the Nerves system based on an env var (e.g.
`NERVES_TARGET_VARIANT=ui|led`), since both firmwares use `MIX_TARGET=rpi4`
but different system deps.

OTA updates work as today: `mix upload nerves-ui.local` and
`mix upload nerves-leds.local`. The shared switch's WAN uplink ensures both
hosts are reachable from a developer laptop on the same network.

## Failure modes

| Scenario                                | Behaviour                                                                                  |
|-----------------------------------------|--------------------------------------------------------------------------------------------|
| Boot ordering (either node first)        | Subscriber connects on join; receives next 33ms broadcast.                                 |
| LED node reboots / cable pulled          | UI + digital twin keep running. LEDs freeze on last frame, resume on reconnect.            |
| Trainer node reboots                     | LEDs hold last frame until trainer restarts (or until watchdog triggers, once added).      |
| Switch / router reboot                   | Both nodes briefly disconnected. `libcluster` reconnects automatically.                    |
| Latency budget                           | Distributed Erlang over wired LAN is ~0.5--3ms; rare spikes ~10ms. 30Hz frame budget is 33ms. |
| Erlang cookie mismatch                   | Nodes refuse to connect. Visible in logs. Caught at first integration test.                |
| Venue network down (no WAN)              | Local cluster still works. Only OTA blocked.                                               |

## Validation plan (V2 testbed)

1. Build both firmwares with V2 build module.
2. Bench setup: reTerminal DM + spare Pi 4B + small switch.
3. Verify nodes auto-cluster (check `Node.list/0` from IEx on both).
4. Verify all 13 boards light up correctly when touch input changes.
5. Soak test: run for 4+ hours at 30Hz, check for:
   - Chain GenServer crashes
   - Mailbox backlog on either side
   - libcluster reconnect events in logs
   - Any visible LED glitching / latency
6. Failure injection:
   - Pull and reconnect the LED node's ethernet cable. LEDs should resume
     within a few seconds of reconnection.
   - Reboot the LED node. Should rejoin and resume.
   - Reboot the UI node. LED node should hold last frame until it returns.

If the testbed survives, V3 is de-risked: same architecture, same
communication path, just more chains on the LED side.

## Open questions

- **Specific libcluster strategy**: static `Epmd` strategy with hardcoded
  hostnames is the proposed default. mDNS-based discovery (e.g.
  `Cluster.Strategy.Mdns` from a community lib) is an alternative that avoids
  the static list, at the cost of an extra dependency. Recommend starting
  with `Epmd` static.
- **Cookie management**: where the cookie file lives (gitignored local,
  injected by env, etc). Suggest a single `config/cookie.exs` loaded only when
  building firmware, with a `.example` file checked in.
- **PubSub topic isolation**: currently `"network_state"` is the only topic.
  As the system grows we may want a `"control"` topic for trainer commands
  (reset, mode change) initiated from the UI side. Out of scope for now.

## Out of scope (for this design)

- LED-side watchdog / fallback render (deferred).
- Touch input forwarding from LED node (LED node has no input).
- Multi-trainer / HA / failover.
- Encrypted distribution channel (TLS for Erlang dist). Closed installation
  network is the trust boundary.
- V3 wiring (separate spec, but uses this architecture).
