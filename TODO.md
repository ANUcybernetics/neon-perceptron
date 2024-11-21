# TODO

- add more checks to the "eps-based equality" thing over many iterations

- add a "training set accuracy" metric to the training loop (or manually do it
  in the Model module)

- write a test pattern which goes 1st layer pattern, 2nd layer pattern, hidden
  pattern, output pattern

- debounce the rotatry encoder (or see if it's a "not yet multiple of 4" issue)

- write a test for the "drift" values

- check the bounds of all activations (under the tanh activation layer) and
  think about scaling

## maybe... but not necessarily

- add "wiggle back and forth" detection for reset training?
