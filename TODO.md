# TODO

- Brendan: touchscreen & digital twin research for neonperceptron

- change name to NeonPerceptron (perhaps John Mayer logo?)

- use the "bias: false" argument (or whatever it's called)

- find out if there's a better way to get the activations from Axon

- set up different Supervisor trees for different targets (in particular, create
  dummy Knob and Display servers for local dev - display could even do a crude
  web mockup of the thing)

- set up dense layers to clamp bias to 0 (or at least "fake" the activations by
  using the layer norm outputs rather than the raw dense_1 outputs)

- (maybe) add "wiggle back and forth" detection for reset training?

- (if necessary) add debounce logic to the rotatry encoder

- rename Knob to Input (in anticipation of having multiple inputs)

- write up a blog post about the design & build
