defmodule NeonPerceptronWeb.KioskLive do
  use NeonPerceptronWeb, :live_view

  alias NeonPerceptron.Trainer

  @tap_step 0.1
  @draw_step 0.015

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "network_state")
    end

    inputs = [0.0, 0.0, 0.0, 0.0]
    push_input(inputs)

    {:ok,
     assign(socket,
       inputs: inputs,
       outputs: [0.0, 0.0],
       iteration: 0,
       loss: 0.0
     )}
  end

  @impl true
  def handle_info({:network_state, state}, socket) do
    outputs = Map.get(state.activations, "output", [0.0, 0.0])

    {:noreply,
     assign(socket,
       outputs: outputs,
       iteration: state.iteration,
       loss: state.loss
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("draw_input", %{"index" => index_str, "type" => type}, socket) do
    index = String.to_integer(index_str)
    step = if type == "down", do: @tap_step, else: @draw_step
    inputs = List.update_at(socket.assigns.inputs, index, &min(&1 + step, 1.0))
    push_input(inputs)
    {:noreply, assign(socket, inputs: inputs)}
  end

  def handle_event("tap_input", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    inputs = List.update_at(socket.assigns.inputs, index, &min(&1 + @tap_step, 1.0))
    push_input(inputs)
    {:noreply, assign(socket, inputs: inputs)}
  end

  def handle_event("reset_weights", _params, socket) do
    Trainer.reset()
    {:noreply, socket}
  end

  def handle_event("clear_inputs", _params, socket) do
    inputs = [0.0, 0.0, 0.0, 0.0]
    push_input(inputs)
    {:noreply, assign(socket, inputs: inputs)}
  end

  defp push_input(inputs) do
    if Process.whereis(NeonPerceptron.Trainer) do
      Trainer.set_web_input(inputs)
    end
  end

  defp brightness_pct(value), do: "#{round(value * 100)}%"

  defp format_loss(loss) when is_float(loss), do: :erlang.float_to_binary(loss, decimals: 4)
  defp format_loss(_), do: "---"

  defp format_output(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 3)

  defp format_output(_), do: "---"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="kiosk"
      phx-hook=".InputDraw"
      style="display: flex; flex-direction: column; width: 100vw; height: 100vh; background: #000; color: #eee; font-family: 'IBM Plex Mono', monospace; user-select: none; touch-action: none;"
    >
      <%!-- Input grid (top portion) --%>
      <div style="flex: 1; display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; gap: 1.5rem; padding: 2rem;">
        <button
          :for={{value, index} <- Enum.with_index(@inputs)}
          data-input-index={index}
          phx-click="tap_input"
          phx-value-index={index}
          style={"
            border: 2px solid #333;
            border-radius: 1rem;
            background: #{input_cell_colour(value)};
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 1.5rem;
            color: #{if value > 0.5, do: "#000", else: "#888"};
            font-family: inherit;
            transition: background 0.1s;
          "}
        >
          {brightness_pct(value)}
        </button>
      </div>

      <%!-- HUD (bottom portion) --%>
      <div style="padding: 1.5rem 2rem; border-top: 1px solid #333; display: flex; flex-direction: column; gap: 1rem;">
        <%!-- Stats row --%>
        <div style="display: flex; justify-content: space-between; font-size: 1.25rem;">
          <span>Iteration: {@iteration}</span>
          <span>Loss: {format_loss(@loss)}</span>
        </div>

        <%!-- Output bars --%>
        <div style="display: flex; gap: 1rem; align-items: center;">
          <span style="font-size: 1.1rem; min-width: 5rem;">Outputs:</span>
          <div :for={{value, index} <- Enum.with_index(@outputs)} style="flex: 1; display: flex; align-items: center; gap: 0.5rem;">
            <span style="font-size: 1rem; min-width: 1.5rem; color: #888;">{index}</span>
            <div style="flex: 1; height: 2rem; background: #222; border-radius: 0.25rem; overflow: hidden;">
              <div style={"height: 100%; width: #{brightness_pct(value)}; background: #4a9; border-radius: 0.25rem; transition: width 0.15s;"}></div>
            </div>
            <span style="font-size: 1rem; min-width: 3.5rem; text-align: right;">{format_output(value)}</span>
          </div>
        </div>

        <%!-- Buttons --%>
        <div style="display: flex; gap: 1rem;">
          <button
            phx-click="reset_weights"
            style="flex: 1; padding: 0.75rem; font-size: 1.25rem; font-family: inherit; background: #333; color: #eee; border: 1px solid #555; border-radius: 0.5rem; cursor: pointer;"
          >
            Reset weights
          </button>
          <button
            phx-click="clear_inputs"
            style="flex: 1; padding: 0.75rem; font-size: 1.25rem; font-family: inherit; background: #333; color: #eee; border: 1px solid #555; border-radius: 0.5rem; cursor: pointer;"
          >
            Clear inputs
          </button>
        </div>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".InputDraw">
      export default {
        mounted() {
          this.drawing = false;

          this.el.addEventListener("pointerdown", (e) => {
            const cell = e.target.closest("[data-input-index]");
            if (!cell) return;
            e.preventDefault();
            this.drawing = true;
            cell.setPointerCapture(e.pointerId);
            this.pushEvent("draw_input", {
              index: cell.dataset.inputIndex,
              type: "down",
            });
          });

          this.el.addEventListener("pointermove", (e) => {
            if (!this.drawing) return;
            const cell = document.elementFromPoint(e.clientX, e.clientY);
            const input = cell && cell.closest("[data-input-index]");
            if (input) {
              this.pushEvent("draw_input", {
                index: input.dataset.inputIndex,
                type: "move",
              });
            }
          });

          this.el.addEventListener("pointerup", () => {
            this.drawing = false;
          });

          this.el.addEventListener("pointercancel", () => {
            this.drawing = false;
          });
        },
      };
    </script>
    """
  end

  defp input_cell_colour(value) do
    r = round(value * 30)
    g = round(value * 200 + 20)
    b = round(value * 180 + 20)
    "rgb(#{r}, #{g}, #{b})"
  end
end
