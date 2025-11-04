# Neon Perceptron

A _Cybernetic Studio_ project by Ben Swift & Brendan Traw.

## Description

An installation which uses
[glowing worms](https://www.adafruit.com/product/5503) to represent the training
and activation weights of a multi-layer perceptron neural network.

Yep, we know that artificial neural networks are not actually brains. One of my
PhD students wrote a
[whole (and excellent!) dissertation about it](http://hdl.handle.net/1885/274243).
But the name is catchy, and the glowing wires do look like worms, so.

## Hardware

**TODO** will update this list once it's built, but the planned BOM is

- Raspberry Pi 4
- Adafruit 12-bit PWM LED Driver
- nOOdz LEDs
- rotary encoder
- seven-segment display

## Software

- Nerves (Elixir) for making the board do cool things
- Axon (Elixir) for the ML training & inference

The code is all in this repo, so you can poke around for yourself.

## Licence

MIT
