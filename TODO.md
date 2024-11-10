# TODO

(in no particular order)

- refactor module names (remove SevenSegment middle namespace)
- add GenServer for managing everything (with mode, weights/model, last_touched,
  current_digit)
- moar tests
- use `0bXXXXXX` literals for the binary representation of the segments
- add a module to abstract the SPI PWM stuff
- get EXLA compiling (or download pre-built binary)
- set up timer for the GenServer (using `send_after`)
- add noise generator (for "animating" the wires)
- add "wiggle back and forth" detection for reset training? maybe.
