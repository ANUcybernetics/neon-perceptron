defmodule NeonPerceptronWeb.KioskLive do
  use NeonPerceptronWeb, :live_view

  alias NeonPerceptron.Trainer

  @tap_step 0.1
  @draw_step 0.015

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "touch")
      Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "network_state")
    end

    inputs = [0.0, 0.0, 0.0, 0.0]
    push_input(inputs)

    {:ok,
     assign(socket,
       inputs: inputs,
       outputs: [0.0, 0.0, 0.0],
       iteration: 0,
       loss: 0.0,
       accuracy: 0.0
     )}
  end

  @impl true
  def handle_info({:touch, type, {x, y}}, socket) when type in [:down, :move] do
    socket = push_event(socket, "server-touch", %{type: to_string(type), x: x, y: y})
    {:noreply, socket}
  end

  def handle_info({:touch, _type, _pos}, socket), do: {:noreply, socket}

  def handle_info({:network_state, state}, socket) do
    outputs = Map.get(state.activations, "output", [0.0, 0.0])

    {:noreply,
     assign(socket,
       outputs: outputs,
       iteration: state.iteration,
       loss: state.loss,
       accuracy: state.accuracy
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

  defp format_loss(loss) when is_number(loss), do: :erlang.float_to_binary(loss / 1, decimals: 4)
  defp format_loss(_), do: "---"

  defp format_accuracy(acc) when is_number(acc),
    do: :erlang.float_to_binary(acc * 100 / 1, decimals: 2) <> "%"

  defp format_accuracy(_), do: "---"

  defp format_iteration(n) when n >= 100_000 do
    exp = n |> :math.log10() |> Float.floor() |> trunc()
    mantissa = n / :math.pow(10, exp)
    :erlang.float_to_binary(mantissa, decimals: 1) <> "e#{exp}"
  end

  defp format_iteration(n), do: Integer.to_string(n)

  defp format_output(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp format_output(_), do: "---"

  defp output_labels do
    build = Application.get_env(:neon_perceptron, :build)

    if function_exported?(build, :output_labels, 0),
      do: build.output_labels(),
      else: ["0", "1", "2"]
  end

  defp output_exemplars do
    build = Application.get_env(:neon_perceptron, :build)

    if function_exported?(build, :training_data, 0) do
      {inputs, targets} = build.training_data()
      num_classes = Nx.axis_size(targets, 1)
      input_rows = Nx.to_list(inputs)
      target_rows = Nx.to_list(targets)

      Enum.zip(input_rows, target_rows)
      |> Enum.group_by(fn {_inp, tgt} -> Enum.find_index(tgt, &(&1 == 1.0)) end, fn {inp, _} -> inp end)
      |> then(fn grouped -> Enum.map(0..(num_classes - 1), &Map.get(grouped, &1, [])) end)
    else
      []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="kiosk"
      phx-hook=".InputDraw"
      style="display: flex; flex-direction: column; width: 100vw; height: 100vh; background: #000; color: #eee; font-family: 'IBM Plex Mono', monospace; user-select: none; touch-action: none;"
    >
      <%!-- Input grid (square, centred) --%>
      <div style="display: flex; justify-content: center; padding: 2rem 2rem 1rem;">
        <div style="width: min(calc(100vw - 4rem), calc(100vh - 24rem)); aspect-ratio: 1; display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; gap: 1.5rem;">
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
      </div>
      <div style="text-align: center; color: #666; font-size: 0.9rem; padding-bottom: 0.5rem;">
        Tap or drag to light up input nodes
      </div>

      <%!-- HUD (bottom portion) --%>
      <div style="flex: 1; padding: 1rem 2rem 1.5rem; border-top: 1px solid #333; display: flex; flex-direction: column; gap: 0.75rem;">
        <%!-- Training stats --%>
        <div style="display: flex; justify-content: space-between; font-size: 1.1rem;">
          <span>Epoch: {format_iteration(@iteration)}</span>
          <span>Loss: {format_loss(@loss)}</span>
          <span>Training accuracy: {format_accuracy(@accuracy)}</span>
        </div>

        <%!-- Classification output --%>
        <div style="color: #888; font-size: 0.9rem; padding-top: 0.25rem;">
          Classification (softmax output)
        </div>
        <div style="display: flex; flex-direction: column; gap: 0.75rem;">
          <div
            :for={{value, {label, patterns}} <- Enum.zip(@outputs, Enum.zip(output_labels(), output_exemplars()))}
            style="display: flex; align-items: center; gap: 0.75rem;"
          >
            <div style="display: flex; align-items: center; gap: 0.5rem; min-width: 8rem;">
              <div :for={pattern <- patterns} style="display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; width: 1.5rem; height: 1.5rem; gap: 1px;">
                <div
                  :for={cell <- pattern}
                  style={"border-radius: 2px; background: #{if cell == 1.0, do: "#4a9", else: "#222"};"}
                />
              </div>
              <span style="font-size: 1rem; color: #aaa;">{label}</span>
            </div>
            <div style="flex: 1; height: 2.5rem; background: #222; border-radius: 0.25rem; overflow: hidden;">
              <div style={"height: 100%; width: #{brightness_pct(value)}; background: #4a9; border-radius: 0.25rem; transition: width 0.15s;"}></div>
            </div>
            <span style="font-size: 1.1rem; min-width: 3.5rem; text-align: right;">{format_output(value)}</span>
          </div>
        </div>

        <%!-- Buttons --%>
        <div style="display: flex; gap: 1rem; padding-top: 0.5rem;">
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

          // Native pointer events (works if Cog DRM or browser forwards touch)
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

          // Server-side touch synthesis (Wayland path: Cog doesn't forward touch)
          this.handleEvent("server-touch", ({type, x, y}) => {
            const target = document.elementFromPoint(x, y);
            if (!target) return;

            const cell = target.closest("[data-input-index]");
            if (cell) {
              this.pushEvent("draw_input", {
                index: cell.dataset.inputIndex,
                type: type,
              });
              return;
            }

            if (type === "down") {
              target.dispatchEvent(new MouseEvent("click", {
                bubbles: true, cancelable: true,
                clientX: x, clientY: y,
              }));
            }
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
