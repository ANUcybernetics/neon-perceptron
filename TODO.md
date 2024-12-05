# TODO

The plan (when I can return to this) is:

- set layer hooks that fire (in `mode: inference`) after each layer that I want
  to light up, and have them send the activations to the model server (or
  _maybe_ the main BrainServer) which can use them, combined with the current
  params, to figure out the activations (and store them somewhere the display
  loop can easily pull them... including being responsive to when they're
  updated)

- (probably) remove the "drift" code, because the slow morphing of the weights
  as the model trains will do the job just fine

- (maybe) add "wiggle back and forth" detection for reset training?

- (if necessary) add debounce logic to the rotatry encoder (or see if it's a
  "not yet multiple of 4" issue)
