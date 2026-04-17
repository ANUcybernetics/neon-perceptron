# Build V2 hardware reference

Physical hardware layout and TLC5947 channel mapping for the
`Builds.V2` installation. Build logic lives in
`lib/neon_perceptron/builds/v2.ex`; this document is the authoritative
source for anything hardware-related so docstrings can stay concise.

**Status:** structurally complete (2026-04-17). Per-chip noodle polarity
(which channel in each pad-pair is the blue vs red wire) is a
best-guess on all chips except `:input_left` chip 0; TASK-21 covers
bench-verifying the remaining ones with `Diag.noodles_all/3`.

## Network

4→2→3 MLP (4 inputs → 2 hidden tanh → 3 softmax outputs).

| Layer    | Size | Physical chips | Populated big LEDs       |
|----------|------|----------------|--------------------------|
| input    | 4    | 4 (1 per node) | 1 RGB + 1 mono per chip  |
| hidden_0 | 2    | 4 (2 per node) | 1 RGB per chip, outward  |
| output   | 3    | 3 (1 per node) | 2 RGB per chip           |
| **total**|      | **11**         |                          |

## Orientation vocabulary

Two senses of "front/back" exist and are deliberately kept separate:

- **Chip-local (`Board.ex`)**: `@front_*` = channels 18/19/20 pad
  triple on one PCB face; `@rear_*` = channels 21/22/23 pad triple on
  the opposite PCB face. Pure silicon-level naming, independent of
  how the board is installed.
- **Installation-wide**: **upstream** = toward input (physically
  above), **downstream** = toward output (physically below). All
  chips are mounted with the same orientation, so ch 18–20 always
  faces upstream and ch 21–23 always faces downstream.

## Chain layout

11 TLC5947 boards on 2 SPI chains on a stock Pi 4B.

| Chain         | SPI bus | spidev        | Chips | XLAT GPIO | Contents                               |
|---------------|---------|---------------|-------|-----------|----------------------------------------|
| `:input_left` | SPI0    | `spidev0.0`   | 2     | GPIO 8    | `input[0]`, `input[2]`                 |
| `:main`       | SPI1*   | `spidev1.0`   | 9     | GPIO 18   | `input[1]`, `input[3]`, 4 hidden, 3 output |

\* Physically connects via the "SPI3" silk-screened connector on the
power distribution board, but the node boards are resoldered to route
SPI1 pins. The silk-screen is stale.

Required overlays in `config/rpi4/config.txt`:

```
dtoverlay=spi0-1cs,cs0_pin=26   # frees GPIO 8 for manual XLAT
dtoverlay=spi1-1cs,cs0_pin=25   # frees GPIO 18 for manual XLAT
```

Both chains use manual XLAT via `Circuits.GPIO` --- kernel CS on
BCM2711 does not reliably latch the TLC5947 on any SPI bus. See
`lib/neon_perceptron/chain.ex`'s `@spi_speed_hz` (1 MHz) for the SPI
clock setting; 25 MHz fails past chip 3 on the 9-chip `:main` ribbon
chain (signal integrity).

### `:main` chip order (0-indexed, MOSI → end)

The invariant is **logical node index ascends physically top-to-bottom**.

| chip | node | physical position |
|------|------|-------------------|
| 0    | `input[1]`    | input column (top), chain-entry end |
| 1    | `input[3]`    | input column |
| 2    | `hidden_0[1]` | col 1 **bottom** |
| 3    | `hidden_0[0]` | col 1 **top** |
| 4    | `hidden_0[0]` | col 2 **top** |
| 5    | `hidden_0[1]` | col 2 **bottom** |
| 6    | `output[2]`   | output column **bottom** |
| 7    | `output[1]`   | output column |
| 8    | `output[0]`   | output column **top** |

Ribbon path: distribution board → chip 0 → chip 1 → (ribbon down) →
chip 2 → chip 3 → (ribbon) → chip 4 → chip 5 → (ribbon down) → chip 6
→ chip 7 → chip 8.

**Back-to-back physical pairs**: chips (3,4) at the tops of the two
hidden columns, chips (2,5) at the bottoms. Each logical hidden node
has diagonal copies: `hidden_0[0]` → chips 3 (col 1 top) + 4 (col 2
top); `hidden_0[1]` → chips 2 (col 1 bottom) + 5 (col 2 bottom).

## TLC5947 channel layout per board role

All chips share the same PCB (24-channel TLC5947). What's *populated*
differs by role.

| Role           | ch 18 / 19 / 20 (**upstream** face) | ch 21 / 22 / 23 (**downstream** face) | Noodle pads driven  |
|----------------|-------------------------------------|---------------------------------------|---------------------|
| Input          | **mono white** (wires tied)         | **RGB**                               | `(0,1)` + `(9,10)`  |
| Hidden col 1 (chips 2, 3) | **RGB**                  | unpopulated                           | none                |
| Hidden col 2 (chips 4, 5) | unpopulated              | **RGB**                               | none                |
| Output         | **RGB**                             | **RGB**                               | `(5,6)` + `(14,15)` |

For rendering, `render_node/2` drives all 6 channels 18–23 with the
same RGB triple for a given node --- unpopulated pads simply don't
light anything, and matching the mono LED's three channels to the
same brightness gives the right result whether the mono is wired to
one channel or all three tied together.

## Noodle routing

Every noodle is a physical wire whose PWM is driven from the *non-hidden*
end. Hidden-side ends terminate on hidden chips for ground reference
only (channels 0–17 on hidden chips are unused).

Each input board drives 2 outgoing-edge noodle pairs (one per hidden
node), and each output board drives 2 incoming-edge noodle pairs (one
per hidden node). Both noodles from a given input/output board
terminate on the **two chips of a single hidden column**:

- `:input_left` chip 0 = `input[0]` → col 1
- `:input_left` chip 1 = `input[2]` → col 2
- `:main` chip 0 = `input[1]` → col 1
- `:main` chip 1 = `input[3]` → col 2
- `:main` chips 6/7/8 = all outputs → col 2

Within a noodle pair, one channel drives the **blue** wire (lit
proportional to positive activation) and the other drives the **red**
wire (lit proportional to absolute value of negative activation).
Which channel in each pair is blue vs red depends on how that specific
chip was physically wired, so it's a per-chip datum.

### Full routing table

| Source chip | Logical node | Pad pair | → Target chip | Target node (top-to-bottom rule) |
|-------------|--------------|----------|----------------|-----------------------------------|
| `:input_left` chip 0 | `input[0]` | (0,1) | `:main` chip 2 | `hidden_0[1]` (col 1 bot) |
| `:input_left` chip 0 | `input[0]` | (9,10) | `:main` chip 3 | `hidden_0[0]` (col 1 top) |
| `:input_left` chip 1 | `input[2]` | (0,1) | `:main` chip 5 | `hidden_0[1]` (col 2 bot) |
| `:input_left` chip 1 | `input[2]` | (9,10) | `:main` chip 4 | `hidden_0[0]` (col 2 top) |
| `:main` chip 0       | `input[1]` | (0,1) | `:main` chip 2 | `hidden_0[1]` |
| `:main` chip 0       | `input[1]` | (9,10)| `:main` chip 3 | `hidden_0[0]` |
| `:main` chip 1       | `input[3]` | (0,1) | `:main` chip 5 | `hidden_0[1]` |
| `:main` chip 1       | `input[3]` | (9,10)| `:main` chip 4 | `hidden_0[0]` |
| `:main` chip 6       | `output[2]`| (5,6)  | `:main` chip 4 | `hidden_0[0]` |
| `:main` chip 6       | `output[2]`| (14,15)| `:main` chip 5 | `hidden_0[1]` |
| `:main` chip 7       | `output[1]`| (5,6)  | `:main` chip 4 | `hidden_0[0]` |
| `:main` chip 7       | `output[1]`| (14,15)| `:main` chip 5 | `hidden_0[1]` |
| `:main` chip 8       | `output[0]`| (5,6)  | `:main` chip 4 | `hidden_0[0]` |
| `:main` chip 8       | `output[0]`| (14,15)| `:main` chip 5 | `hidden_0[1]` |

The rule generalising this: for input boards, pads `(0,1)` → lower
chip of the target column, `(9,10)` → upper chip. For output boards,
`(5,6)` → upper chip, `(14,15)` → lower chip. (The different
pad-to-height mapping reflects the different PCB orientation of
output-column boards relative to the input column.)

## Per-chip noodle polarity

Best-guess defaults for V2 (mirroring the bench-verified
`:input_left` chip 0): on every input board, pad pair `(0,1)` is
`blue_ch=1, red_ch=0` and pair `(9,10)` is `blue_ch=9, red_ch=10`. On
every output board, pad pair `(5,6)` is `blue_ch=6, red_ch=5` and
pair `(14,15)` is `blue_ch=14, red_ch=15`.

Verify at the bench with:

```elixir
alias NeonPerceptron.Diag
Diag.pause_ticker()
Diag.noodles_all(:main, :blue)    # every pair's blue_ch at full bright
# Walk the installation; every lit noodle should be blue.
Diag.noodles_all(:main, :red)     # every pair's red_ch at full bright
Diag.noodles_all(:input_left, :blue)
Diag.dark_all()
Diag.resume_ticker()
```

For any pair that lights up the wrong colour, swap `blue_ch`/`red_ch`
in that noodle spec (in `v2.ex`'s `input_noodles/0` or
`output_noodles/0`) --- or, if only specific chips need swapping,
break the shared templates out into per-chip literals.

## Characterising new channels

`Diag.light/4` lights a single channel on a single chip; `Diag.light_chip/3`
lights a whole chip; `Diag.light_all/2-3` lights one channel across every
chip. See the moduledoc for examples.

## Historical channel names (Brendan's early test scripts)

From `test0.py` / `test3.py` (single-chip Adafruit CircuitPython tests):

```
filament_channel = 17
BFLa_channel     = 12
BFLb_channel     = 13
```

Likely V3 or prototype wiring --- not part of V2's current channel
assignments.
