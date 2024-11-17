# TODO

- complete the transition of Model to a genserver, use Loop.train_step, and make
  a `get_activations` call to get the activations

- have just one of the Knob interrupts send a "updated" message to the main
  brainserver to update `:updated_at`

- create an `Input` struct, which stores the current display bit pattern plus a
  list of freq/phase tuples so that if it's in "drift" mode (> 30s since last
  knob movement) then each bit will be sinusoidally modulated but in a way that
  each digit "starts" from the last known knob-set bit pattern

- activations could normalise (perhaps by layer)

- set knob handler to iterate through the bit patterns (basically just do a mod
  128 on the current return value)

- then, the main loop should:
  - check update_at
  - display either the current bit pattern or the current "drift values"
  - based on display, get the activations from the model and display them too
  - (maybe) add one more level of modulation, but perhaps not

## maybe... but not necessarily

- add "wiggle back and forth" detection for reset training?
