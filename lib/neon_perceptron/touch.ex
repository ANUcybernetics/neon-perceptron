defmodule NeonPerceptron.Touch do
  use GenServer

  require Logger

  @type touch_event :: {:touch, :down | :move | :up, {non_neg_integer(), non_neg_integer()}}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    callback = Keyword.get(opts, :callback)

    state = %{
      x: 0,
      y: 0,
      touching: false,
      callback: callback
    }

    case find_and_open_device() do
      {:ok, device_path} ->
        Logger.info("Touch device opened: #{device_path}")
        {:ok, Map.put(state, :device, device_path)}

      :error ->
        Logger.warning("No touch device found - touch input disabled")
        {:ok, Map.put(state, :device, nil)}
    end
  end

  @impl true
  def handle_info({:input_event, _path, events}, state) do
    {:noreply, process_events(events, state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp process_events([], state), do: state

  defp process_events([event | rest], state) do
    process_events(rest, process_event(event, state))
  end

  defp process_event({:ev_abs, :abs_mt_position_x, x}, state), do: %{state | x: x}
  defp process_event({:ev_abs, :abs_mt_position_y, y}, state), do: %{state | y: y}

  defp process_event({:ev_key, :btn_touch, 1}, state) do
    notify(state, :down)
    %{state | touching: true}
  end

  defp process_event({:ev_key, :btn_touch, 0}, state) do
    notify(state, :up)
    %{state | touching: false}
  end

  defp process_event({:ev_syn, :syn_report, 0}, %{touching: true} = state) do
    notify(state, :move)
    state
  end

  defp process_event(_event, state), do: state

  defp notify(%{callback: nil, x: x, y: y}, type) do
    Phoenix.PubSub.broadcast(NeonPerceptron.PubSub, "touch", {:touch, type, {x, y}})
  end

  defp notify(%{callback: callback, x: x, y: y}, type) do
    send(callback, {:touch, type, {x, y}})
  end

  defp find_and_open_device do
    case InputEvent.enumerate() do
      devices when is_list(devices) ->
        devices
        |> Enum.find(fn {_path, info} ->
          String.contains?(String.downcase(info.name), "greentouch")
        end)
        |> case do
          {path, _info} ->
            case InputEvent.start_link(path: path, receiver: self()) do
              {:ok, _pid} -> {:ok, path}
              _ -> :error
            end

          nil ->
            :error
        end

      _ ->
        :error
    end
  end
end
