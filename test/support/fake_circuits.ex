defmodule NeonPerceptron.FakeCircuits do
  @moduledoc """
  Recording SPI and GPIO backends for host tests.

  `install/1` points `Circuits.SPI` and `Circuits.GPIO` at these backends
  for processes that open a bus or pin afterwards. Every transfer and pin
  write is sent to the installing process as a message, so a test sees the
  bus activity of a `Chain` in the order it happened:

  - `{:spi, bus_name, data}`
  - `{:gpio_open, label, direction, initial_value}`
  - `{:gpio, label, value}`
  - `{:gpio_close, label}`

  A transfer reads back what the previous transfer on that bus sent, as a
  daisy chain whose length matches the frame would. Pass
  `readback: {:flip, byte_index}` to corrupt one bit of every read-back
  byte at that index instead.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def install(opts \\ []) do
    previous = %{
      spi: Application.get_env(:circuits_spi, :default_backend),
      gpio: Application.get_env(:circuits_gpio, :default_backend)
    }

    backend_opts = [recorder: self(), readback: Keyword.get(opts, :readback, :echo)]
    Application.put_env(:circuits_spi, :default_backend, {__MODULE__.SPI, backend_opts})
    Application.put_env(:circuits_gpio, :default_backend, {__MODULE__.GPIO, backend_opts})

    on_exit(fn ->
      restore(:circuits_spi, previous.spi)
      restore(:circuits_gpio, previous.gpio)
    end)

    :ok
  end

  defp restore(app, nil), do: Application.delete_env(app, :default_backend)
  defp restore(app, backend), do: Application.put_env(app, :default_backend, backend)

  defmodule SPI do
    @moduledoc false
    @behaviour Circuits.SPI.Backend

    defstruct [:bus_name, :recorder, :readback, :last_sent]

    @impl true
    def bus_names(_options), do: []

    @impl true
    def open(bus_name, options) do
      {:ok, last_sent} = Agent.start_link(fn -> nil end)

      {:ok,
       %__MODULE__{
         bus_name: bus_name,
         recorder: Keyword.fetch!(options, :recorder),
         readback: Keyword.fetch!(options, :readback),
         last_sent: last_sent
       }}
    end

    @impl true
    def info, do: %{name: __MODULE__}
  end

  defmodule GPIO do
    @moduledoc false
    @behaviour Circuits.GPIO.Backend

    defstruct [:label, :recorder]

    @impl true
    def enumerate(_options), do: []

    @impl true
    def identifiers(_gpio_spec, _options), do: {:error, :not_found}

    @impl true
    def status(_gpio_spec, _options), do: {:error, :not_found}

    @impl true
    def open(label, direction, options) do
      recorder = Keyword.fetch!(options, :recorder)
      send(recorder, {:gpio_open, label, direction, Keyword.fetch!(options, :initial_value)})
      {:ok, %__MODULE__{label: label, recorder: recorder}}
    end

    @impl true
    def backend_info, do: %{name: __MODULE__}
  end
end

defimpl Circuits.SPI.Bus, for: NeonPerceptron.FakeCircuits.SPI do
  def config(_bus), do: {:ok, %{mode: 0, bits_per_word: 8, speed_hz: 1_000_000, delay_us: 10}}

  def transfer(bus, data) do
    data = IO.iodata_to_binary(data)
    send(bus.recorder, {:spi, bus.bus_name, data})
    previous = Agent.get_and_update(bus.last_sent, fn previous -> {previous, data} end)
    {:ok, read_back(bus.readback, previous, byte_size(data))}
  end

  def close(_bus), do: :ok

  def max_transfer_size(_bus), do: 4096

  defp read_back(_mode, nil, size), do: :binary.copy(<<0>>, size)

  defp read_back(_mode, previous, size) when byte_size(previous) != size,
    do: :binary.copy(<<0>>, size)

  defp read_back(:echo, previous, _size), do: previous

  defp read_back({:flip, index}, previous, size) when index < size do
    <<before::binary-size(index), byte, rest::binary>> = previous
    <<before::binary, Bitwise.bxor(byte, 1), rest::binary>>
  end
end

defimpl Circuits.GPIO.Handle, for: NeonPerceptron.FakeCircuits.GPIO do
  def read(_handle), do: 0

  def write(handle, value) do
    send(handle.recorder, {:gpio, handle.label, value})
    :ok
  end

  def set_direction(_handle, _direction), do: :ok

  def set_pull_mode(_handle, _mode), do: :ok

  def close(handle) do
    send(handle.recorder, {:gpio_close, handle.label})
    :ok
  end

  def set_interrupts(_handle, _trigger, _options), do: :ok
end
