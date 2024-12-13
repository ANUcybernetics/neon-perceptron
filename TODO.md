# TODO

- find out if there's a better way to get the activations from Axon

- set up different Supervisor trees for different targets (in particular, create
  dummy Knob and Display servers for local dev - display could even do a crude
  web mockup of the thing)

- set up dense layers to clamp bias to 0

- (maybe) add "wiggle back and forth" detection for reset training?

- (if necessary) add debounce logic to the rotatry encoder (or see if it's a
  "not yet multiple of 4" issue)

- rename Knob to Input (in anticipation of having multiple inputs)
