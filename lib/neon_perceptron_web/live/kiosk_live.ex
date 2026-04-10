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
       accuracy: 0.0,
       diagram_nodes: [],
       diagram_edges: [],
       diagram_grids: []
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
    {diagram_nodes, diagram_edges, diagram_grids} = compute_diagram(state)

    {:noreply,
     assign(socket,
       outputs: outputs,
       iteration: state.iteration,
       loss: state.loss,
       accuracy: state.accuracy,
       diagram_nodes: diagram_nodes,
       diagram_edges: diagram_edges,
       diagram_grids: diagram_grids
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
      <div style="display: flex; justify-content: center; padding: 1.5rem 2rem 0.5rem;">
        <div style="width: min(calc(100vw - 4rem), calc(100vh - 30rem)); aspect-ratio: 1; display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; gap: 1.5rem;">
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
      <div style="text-align: center; color: #666; font-size: 0.8rem; padding-bottom: 0.25rem;">
        Tap or drag to light up input nodes
      </div>

      <%!-- HUD (bottom portion) --%>
      <div style="flex: 1; min-height: 0; padding: 0.75rem 2rem 1.5rem; border-top: 1px solid #333; display: flex; flex-direction: column; gap: 0.5rem;">
        <%!-- Main area: network diagram + output bars --%>
        <div style="flex: 1; display: flex; gap: 1rem; min-height: 0;">
          <%!-- Network diagram (2/3 width) --%>
          <div style="flex: 2; min-width: 0; min-height: 0;">
            <svg viewBox="0 0 400 200" preserveAspectRatio="xMidYMid meet" style="width: 100%; height: 100%; display: block;">
              <rect
                :for={g <- @diagram_grids}
                x={g.x} y={g.y} width={g.w} height={g.h}
                rx={g.rx} fill={g.fill}
              />
              <line
                :for={e <- @diagram_edges}
                x1={e.x1} y1={e.y1} x2={e.x2} y2={e.y2}
                stroke={e.stroke} stroke-opacity={e.opacity} stroke-width={e.width}
              />
              <circle
                :for={n <- @diagram_nodes}
                cx={n.x} cy={n.y} r="9"
                fill={n.fill} stroke="#555" stroke-width="1"
              />
            </svg>
          </div>
          <%!-- Vertical output bars (1/3 width) --%>
          <div style="flex: 1; display: flex; gap: 0.5rem; align-items: stretch;">
            <div
              :for={{value, {label, patterns}} <- Enum.zip(@outputs, Enum.zip(output_labels(), output_exemplars()))}
              style="flex: 1; display: flex; flex-direction: column; align-items: center; gap: 0.2rem;"
            >
              <span style="font-size: 0.85rem; color: #aaa;">{format_output(value)}</span>
              <div style="flex: 1; width: 100%; max-width: 3.5rem; background: #222; border-radius: 0.25rem; position: relative; overflow: hidden;">
                <div style={"position: absolute; bottom: 0; width: 100%; height: #{brightness_pct(value)}; background: #4a9; border-radius: 0.25rem; transition: height 0.15s;"} />
              </div>
              <span style="font-size: 0.7rem; color: #888;">{label}</span>
              <div style="display: flex; flex-direction: row; gap: 3px; align-items: center;">
                <div :for={pattern <- patterns} style="display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; width: 1rem; height: 1rem; gap: 1px;">
                  <div
                    :for={cell <- pattern}
                    style={"border-radius: 1px; background: #{if cell == 1.0, do: "#4a9", else: "#222"};"}
                  />
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Bottom strip: stats (left) + buttons (right) --%>
        <div style="display: flex; gap: 1rem; align-items: stretch;">
          <div style="display: flex; flex-direction: column; justify-content: center; gap: 0.15rem; font-size: 0.95rem; min-width: 14rem;">
            <span>Epoch: {format_iteration(@iteration)}</span>
            <span>Loss: {format_loss(@loss)}</span>
            <span>Accuracy: {format_accuracy(@accuracy)}</span>
          </div>
          <button
            phx-click="reset_weights"
            style="flex: 1; font-size: 1.1rem; font-family: inherit; background: #333; color: #eee; border: 1px solid #555; border-radius: 0.5rem; cursor: pointer;"
          >
            Reset weights
          </button>
          <button
            phx-click="clear_inputs"
            style="flex: 1; font-size: 1.1rem; font-family: inherit; background: #333; color: #eee; border: 1px solid #555; border-radius: 0.5rem; cursor: pointer;"
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

  defp compute_diagram(state) do
    topology = state.topology
    layers = topology.layers
    num_layers = length(layers)

    positions =
      Map.new(layers, fn layer ->
        li = Enum.find_index(layers, &(&1 == layer))
        size = topology.sizes[layer]
        x = round(65 + li / (num_layers - 1) * 270)
        pts = for i <- 0..(size - 1), do: {x, round(15 + (i + 0.5) / size * 170)}
        {layer, pts}
      end)

    nodes =
      Enum.flat_map(layers, fn layer ->
        acts = Map.get(state.activations, layer, [])

        Enum.with_index(acts, fn act, i ->
          {x, y} = Enum.at(positions[layer], i)
          %{x: x, y: y, fill: node_fill(act)}
        end)
      end)

    edges =
      layers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index()
      |> Enum.flat_map(fn {[from_layer, to_layer], li} ->
        from_size = topology.sizes[from_layer]
        to_size = topology.sizes[to_layer]
        kernel = Map.get(state.weights, "dense_#{li}", [])
        from_acts = Map.get(state.activations, from_layer, [])

        for i <- 0..(from_size - 1), j <- 0..(to_size - 1) do
          contribution = Enum.at(from_acts, i, 0.0) * Enum.at(kernel, i * to_size + j, 0.0)
          {x1, y1} = Enum.at(positions[from_layer], i)
          {x2, y2} = Enum.at(positions[to_layer], j)
          edge_attrs(x1, y1, x2, y2, contribution)
        end
      end)

    grids = input_indicator_grids(positions) ++ output_exemplar_grids(positions)

    {nodes, edges, grids}
  end

  @grid_cell 5
  @grid_gap 1
  @grid_stride @grid_cell + @grid_gap

  defp input_indicator_grids(positions) do
    positions["input"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {{nx, ny}, idx} ->
      gx = nx - 24
      gy = ny - @grid_stride

      for row <- 0..1, col <- 0..1 do
        %{
          x: gx + col * @grid_stride, y: gy + row * @grid_stride,
          w: @grid_cell, h: @grid_cell, rx: 1,
          fill: if(row * 2 + col == idx, do: "#3c8cff", else: "#333")
        }
      end
    end)
  end

  defp output_exemplar_grids(positions) do
    exemplars = output_exemplars()

    positions["output"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {{nx, ny}, class_idx} ->
      patterns = Enum.at(exemplars, class_idx, [])

      patterns
      |> Enum.with_index()
      |> Enum.flat_map(fn {pattern, pat_idx} ->
        gx = nx + 16 + pat_idx * (@grid_stride * 2 + 3)
        gy = ny - @grid_stride

        pattern
        |> Enum.with_index()
        |> Enum.map(fn {val, cell_idx} ->
          %{
            x: gx + rem(cell_idx, 2) * @grid_stride,
            y: gy + div(cell_idx, 2) * @grid_stride,
            w: @grid_cell, h: @grid_cell, rx: 1,
            fill: if(val == 1.0, do: "#3c8cff", else: "#333")
          }
        end)
      end)
    end)
  end

  defp node_fill(act) do
    a = abs(act)

    if act >= 0 do
      "rgb(#{round(20 + a * 40)},#{round(20 + a * 120)},#{round(20 + a * 235)})"
    else
      "rgb(#{round(20 + a * 235)},#{round(20 + a * 120)},#{round(20 + a * 20)})"
    end
  end

  defp edge_attrs(x1, y1, x2, y2, contribution) do
    mag = min(abs(contribution), 2) / 2
    c = :math.pow(mag, 0.45)

    {stroke, opacity, width} =
      cond do
        mag < 0.001 -> {"#444", 0.15, 0.5}
        contribution >= 0 -> {"rgb(60,140,255)", 0.15 + c * 0.7, 0.5 + c * 3}
        true -> {"rgb(255,140,40)", 0.15 + c * 0.7, 0.5 + c * 3}
      end

    %{
      x1: x1, y1: y1, x2: x2, y2: y2,
      stroke: stroke,
      opacity: Float.round(opacity, 2),
      width: Float.round(width, 1)
    }
  end

  defp input_cell_colour(value) do
    r = round(value * 30)
    g = round(value * 200 + 20)
    b = round(value * 180 + 20)
    "rgb(#{r}, #{g}, #{b})"
  end
end
