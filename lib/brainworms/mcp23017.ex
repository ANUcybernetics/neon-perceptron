defmodule Brainworms.MCP23017 do
  alias Circuits.I2C
  # MCP23017 default address; adjust if necessary
  @i2c_address 0x27

  # MCP23017 Register Addresses
  # I/O direction for Port A
  @iodira 0x00
  # I/O direction for Port B
  @iodirb 0x01
  # GPIO register for Port A
  @gpioa 0x12
  # GPIO register for Port B
  @gpiob 0x13

  # Initializes the I2C connection and configures MCP23017
  def init!(bus) do
    # Configure all pins on Port A as outputs
    I2C.write!(bus, @i2c_address, <<@iodira, 0x00>>)

    # Configure PB0 and PB1 on Port B as inputs, keep others as outputs
    I2C.write!(bus, @i2c_address, <<@iodirb, 0x03>>)

    :ok
  end

  # Write a byte to Port A
  def write_port_a(bus, data) do
    I2C.write(bus, @i2c_address, <<@gpioa>> <> data)
  end

  # Read the state of PB0 and PB1 on Port B
  def read_port_b(bus) do
    {:ok, <<state>>} = I2C.write_read(bus, @i2c_address, <<@gpiob>>, 1)
    # Mask to get only PB0 and PB1
    Bitwise.&&&(state, 0x03)
  end
end
