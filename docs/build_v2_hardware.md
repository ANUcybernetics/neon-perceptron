# Build V2 hardware reference

Physical hardware layout and TLC5947 channel mapping for the Builds.V2
installation. Build logic lives in `lib/neon_perceptron/builds/v2.ex`;
this document is the authoritative source for anything hardware-related
so docstrings can stay concise.

**Status:** work-in-progress. Per-channel mappings are being
characterised at the bench --- see TASK-17. Tables below mark `?` for
unknown entries.

## Installation overview

4→2→3 neural network (4 inputs → 2 hidden gelu → 3 softmax outputs).
Each logical node is visualised by one or two physical TLC5947 boards
driving big LEDs and/or noodles.

| Node type | Count | Boards per node | Total boards |
|-----------|-------|-----------------|--------------|
| input     | 4     | 1               | 4            |
| hidden_0  | 2     | 2 (front + rear)| 4            |
| output    | 3     | 1               | 3            |
| **total** |       |                 | **11**       |

## Chain layout

13 TLC5947 boards on 2 SPI chains on a stock Raspberry Pi 4B. The power
distribution board (v1.2) is a passive parallel breakout: all 5
connectors carry the same GPIO signals. Node boards are hard-wired to
specific SPI bus pins on their PCB.

| Chain         | SPI bus | spidev        | Chips | XLAT GPIO | Contents                          |
|---------------|---------|---------------|-------|-----------|-----------------------------------|
| `:input_left` | SPI0    | `spidev0.0`   | 2     | GPIO 8    | input[0], input[2]                |
| `:main`       | SPI1²   | `spidev1.0`   | 9     | GPIO 18   | input[1], input[3], hidden×4, output×3 |

² Physically connects via the connector silk-screened "SPI3" on the
power distribution board, but the node boards have been re-soldered to
route SPI1 pins.

### Overlays (config/rpi4/config.txt)

```
dtoverlay=spi0-1cs,cs0_pin=26   # frees GPIO 8 for manual XLAT
dtoverlay=spi1-1cs,cs0_pin=25   # frees GPIO 18 for manual XLAT
```

Both chains use **manual XLAT**. On Pi 4, kernel CE0 does not reliably
latch the TLC5947 on any SPI bus (aux SPI controllers in particular),
so `Chain.xlat_gpio` pulses the latch GPIO after each transfer.

## TLC5947 channel reference

Each TLC5947 provides 24 PWM channels (12-bit each). The PCB pad layout
(as designed):

- Channels **0--17**: 9 noodle pad pairs (6 per input/output board are
  populated; hidden boards have none populated)
- Channels **18--20**: "front" big-LED pad triple (B, G, R)
- Channels **21--23**: "rear" big-LED pad triple (B, G, R)

**Important:** per-board population and wiring is non-uniform. The
channel → LED mapping depends on the board role (input / hidden / output)
and orientation. The tables below record the actual wiring observed at
the bench.

### Input board --- `:input_left` chip 0

Board role: drives outgoing-edge noodles from input[0] to the three
hidden nodes (front column), plus one big LED.

| TLC5947 ch | Physical wire / LED                         | Confirmed |
|------------|---------------------------------------------|-----------|
| 0          | red noodle to `:main` chip 3 (+ edge 0)     | ✅ 2026-04-17 |
| 1          | blue noodle to `:main` chip 3 (− edge 0)    | ✅ 2026-04-17 |
| 2          | ?                                           |           |
| 3          | ?                                           |           |
| 4          | ?                                           |           |
| 5          | ?                                           |           |
| 6          | ?                                           |           |
| 7          | ?                                           |           |
| 8          | ?                                           |           |
| 9          | blue noodle to `:main` chip 4 (− edge 1)    | ✅ 2026-04-17 |
| 10         | red noodle to `:main` chip 4 (+ edge 1)     | ⚠️ dark at bench, suspected physical noodle fault |
| 11         | ?                                           |           |
| 12         | ?                                           |           |
| 13         | ?                                           |           |
| 14         | ?                                           |           |
| 15         | ?                                           |           |
| 16         | ?                                           |           |
| 17         | ?                                           |           |
| 18         | ? (front big LED blue? or noodle?)          |           |
| 19         | ? (front big LED green?)                    |           |
| 20         | ? (front big LED red?)                      |           |
| 21         | ? (rear big LED blue?)                      |           |
| 22         | ? (rear big LED green?)                     |           |
| 23         | ? (rear big LED red?)                       |           |

**Observed mirroring:** channels 0/1 and 9/10 are both noodle pairs,
but with opposite polarity-to-channel mapping (0=red/1=blue vs
9=blue/10=red). This reflects the physical orientation of the two
noodle ends on the board.

### Input board --- `:input_left` chip 1

Same board design as chip 0, driving outgoing edges from input[2].

| TLC5947 ch | Physical wire / LED | Confirmed |
|------------|---------------------|-----------|
| 0--23      | ?                   | TBD       |

### Input board --- `:main` chips 0, 1

Same board design as `:input_left` chips, driving outgoing edges from
input[1] and input[3].

| TLC5947 ch | Physical wire / LED | Confirmed |
|------------|---------------------|-----------|
| 0--23      | ?                   | TBD       |

### Hidden board --- `:main` chips 2, 3 (front) and 4, 5 (rear)

Hidden boards drive no noodles (noodles terminate here only as voltage
reference). Each hidden board has a single RGB big LED; which channel
triple drives it is TBD.

| TLC5947 ch | Physical wire / LED | Confirmed |
|------------|---------------------|-----------|
| 0--17      | no LED (voltage reference only) | TBD |
| 18--23     | ? (one RGB big LED) | TBD       |

### Output board --- `:main` chips 6, 7, 8

Drives incoming-edge noodles from the 2 hidden nodes, plus front and
rear big LEDs (both RGB).

| TLC5947 ch | Physical wire / LED | Confirmed |
|------------|---------------------|-----------|
| 0--23      | ?                   | TBD       |

## Miscellaneous

### Historical channel names (Brendan's test scripts)

From `test0.py` / `test3.py` (single-chip Adafruit CircuitPython tests):

```
filament_channel = 17
BFLa_channel     = 12
BFLb_channel     = 13
```

Unclear which board type / variant these applied to. Kept here for
reference in case they turn up during characterisation.

### Signal integrity observations

- 30 Hz refresh produces visible fine flicker during the "on" phase;
  see TASK-17 AC #5 for hypotheses (25 MHz → 30 MHz SPI, render-on-change).
- On `:main` with 9 chips, LEDs past chip ~2 do not respond reliably
  to `TestPattern`. Under investigation (TASK-17 AC #2).

## How to characterise a channel

On the Pi with firmware running:

```elixir
alias NeonPerceptron.Diag
Diag.pause_ticker()
Diag.light(:input_left, 0, 5, 1.0)  # chain, chip_index, channel, brightness
# observe which LED / noodle / wire lights up, record in the table above
Diag.dark(:input_left)
```

Each `light/4` call deterministically blanks the chain before lighting
the requested channel --- no hidden state between calls.
