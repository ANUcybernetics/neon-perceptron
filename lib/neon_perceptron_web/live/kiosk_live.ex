defmodule NeonPerceptronWeb.KioskLive do
  use NeonPerceptronWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(NeonPerceptron.PubSub, "touch")
    {:ok, assign(socket, touch_count: 0, last_x: 0, last_y: 0)}
  end

  @impl true
  def handle_info({:touch, type, {x, y}}, socket) do
    socket =
      socket
      |> then(fn s ->
        if type == :down,
          do: assign(s, touch_count: s.assigns.touch_count + 1, last_x: x, last_y: y),
          else: assign(s, last_x: x, last_y: y)
      end)
      |> push_event("server-touch", %{type: type, x: x, y: y})

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="touch-canvas"
      phx-hook=".TouchPulse"
      style="position: relative; width: 100vw; height: 100vh; background: #000; overflow: hidden; touch-action: none;"
    >
      <div style="position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; color: #0f0; font-family: monospace; font-size: 2rem; pointer-events: none;">
        <div style="text-align: center;">
          <h1 style="font-size: 3rem; margin-bottom: 1rem;">Neon Perceptron</h1>
          <p>Touch anywhere (count: {@touch_count}, x: {@last_x}, y: {@last_y})</p>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TouchPulse">
      const TOUCH_TYPE_TO_POINTER = {down: "pointerdown", move: "pointermove", up: "pointerup"};

      export default {
        mounted() {
          this.handleEvent("server-touch", ({type, x, y}) => {
            const target = document.elementFromPoint(x, y) || document.body;
            const pointerType = TOUCH_TYPE_TO_POINTER[type];
            if (pointerType) {
              target.dispatchEvent(new PointerEvent(pointerType, {
                bubbles: true, cancelable: true,
                clientX: x, clientY: y,
                pointerId: 1, pointerType: "touch", isPrimary: true,
                pressure: type === "up" ? 0 : 0.5,
              }));
            }
            if (type === "down") this.spawnCircle(x, y);
          });
        },

        spawnCircle(x, y) {
          const circle = document.createElement("div");
          Object.assign(circle.style, {
            position: "absolute",
            left: `${x}px`,
            top: `${y}px`,
            width: "0px",
            height: "0px",
            borderRadius: "50%",
            background: "radial-gradient(circle, #0f0 0%, transparent 70%)",
            transform: "translate(-50%, -50%)",
            pointerEvents: "none",
            opacity: "0.8",
          });
          this.el.appendChild(circle);

          const start = performance.now();
          const duration = 1200;
          const maxSize = 120;

          const animate = (now) => {
            const t = (now - start) / duration;
            if (t >= 1) { circle.remove(); return; }
            const size = maxSize * t;
            const pulse = 0.8 * (1 - t) * (0.6 + 0.4 * Math.sin(t * Math.PI * 4));
            circle.style.width = `${size}px`;
            circle.style.height = `${size}px`;
            circle.style.opacity = `${pulse}`;
            requestAnimationFrame(animate);
          };
          requestAnimationFrame(animate);
        },
      };
    </script>
    """
  end
end
