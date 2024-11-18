# TODO

- create an `Input` struct, which stores the current display bit pattern plus a
  list of freq/phase tuples so that if it's in "drift" mode (> 30s since last
  knob movement) then each bit will be sinusoidally modulated but in a way that
  each digit "starts" from the last known knob-set bit pattern

- activations could normalise (perhaps by layer)

- then, the main loop should:
  - check update_at
  - display either the current bit pattern or the current "drift values"
  - based on display, get the activations from the model and display them too
  - (maybe) add one more level of modulation, but perhaps not

## maybe... but not necessarily

- add "wiggle back and forth" detection for reset training?
