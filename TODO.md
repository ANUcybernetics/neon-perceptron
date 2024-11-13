# TODO

(in no particular order)

- run Model.init_loop in BrainServer init, and maybe train for one epoch, and
  the :epoch_completed event handler should send the whole model state to the
  BrainServer (perhaps a :model_updated event or something)

       Model.init_loop |> Axon.Loop.run(Model.training_set())

- for lighting the wires, you can pull the model state from
  loop.step_state.model_state, and then run predict_fn perhaps? or do it
  manually (e.g. to get the activations of the different wires... not sure if
  there's a nice way to do this)

- rotary encoder using <https://hexdocs.pm/rotary_encoder/RotaryEncoder.html>
  (see if changes are necessary for circuits v2)
- moar tests

## maybe... but not necessarily

- add "wiggle back and forth" detection for reset training?
- get EXLA compiling (or download pre-built binary)
- add a UI (for the rpi4 touchscreen) with
  [Scenic](https://hexdocs.pm/scenic/welcome.html)
