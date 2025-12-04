import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { Line2 } from "three/addons/lines/Line2.js";
import { LineMaterial } from "three/addons/lines/LineMaterial.js";
import { LineGeometry } from "three/addons/lines/LineGeometry.js";

const SEVEN_SEGMENT_PATTERNS = [
  [1, 1, 1, 1, 1, 1, 0], // 0: a,b,c,d,e,f
  [0, 1, 1, 0, 0, 0, 0], // 1: b,c
  [1, 1, 0, 1, 1, 0, 1], // 2: a,b,d,e,g
  [1, 1, 1, 1, 0, 0, 1], // 3: a,b,c,d,g
  [0, 1, 1, 0, 0, 1, 1], // 4: b,c,f,g
  [1, 0, 1, 1, 0, 1, 1], // 5: a,c,d,f,g
  [1, 0, 1, 1, 1, 1, 1], // 6: a,c,d,e,f,g
  [1, 1, 1, 0, 0, 0, 0], // 7: a,b,c
  [1, 1, 1, 1, 1, 1, 1], // 8: all
  [1, 1, 1, 1, 0, 1, 1], // 9: a,b,c,d,f,g
];

function createSevenSegmentGroup(digit, size = 0.4) {
  const group = new THREE.Group();

  // Backing panel dimensions
  const panelWidth = size * 0.7;
  const panelHeight = size * 1.1;
  const panelDepth = size * 0.08;

  // Create dark backing panel with bevelled edge effect
  const panelGeometry = new THREE.BoxGeometry(
    panelWidth,
    panelHeight,
    panelDepth,
  );
  const panelMaterial = new THREE.MeshStandardMaterial({
    color: 0x0a0a0a,
    roughness: 0.8,
    metalness: 0.1,
  });
  const panel = new THREE.Mesh(panelGeometry, panelMaterial);
  panel.position.z = -panelDepth / 2;
  group.add(panel);

  // Inner recessed area (slightly lighter, creates depth)
  const innerWidth = panelWidth * 0.85;
  const innerHeight = panelHeight * 0.9;
  const innerGeometry = new THREE.PlaneGeometry(innerWidth, innerHeight);
  const innerMaterial = new THREE.MeshStandardMaterial({
    color: 0x111111,
    roughness: 0.9,
    side: THREE.DoubleSide,
  });
  const innerPanel = new THREE.Mesh(innerGeometry, innerMaterial);
  innerPanel.position.z = 0.001;
  group.add(innerPanel);

  // Segment dimensions - classic elongated hexagon style
  const segmentLength = size * 0.28;
  const segmentThickness = size * 0.06;
  const halfHeight = size * 0.38;
  const halfWidth = segmentLength / 2 + segmentThickness * 0.3;

  // Create segment shape (elongated hexagon for that classic LED look)
  const segmentShape = new THREE.Shape();
  const sl = segmentLength / 2;
  const st = segmentThickness / 2;
  const taper = st * 0.7;
  segmentShape.moveTo(-sl + taper, 0);
  segmentShape.lineTo(-sl, st);
  segmentShape.lineTo(sl, st);
  segmentShape.lineTo(sl + taper, 0);
  segmentShape.lineTo(sl, -st);
  segmentShape.lineTo(-sl, -st);
  segmentShape.closePath();

  const segmentGeometry = new THREE.ShapeGeometry(segmentShape);
  const vertSegmentGeometry = segmentGeometry.clone();
  vertSegmentGeometry.rotateZ(Math.PI / 2);

  const segments = [];
  const positions = [
    // a: top horizontal
    { x: 0, y: halfHeight, geom: segmentGeometry },
    // b: top-right vertical
    { x: halfWidth, y: halfHeight / 2, geom: vertSegmentGeometry },
    // c: bottom-right vertical
    { x: halfWidth, y: -halfHeight / 2, geom: vertSegmentGeometry },
    // d: bottom horizontal
    { x: 0, y: -halfHeight, geom: segmentGeometry },
    // e: bottom-left vertical
    { x: -halfWidth, y: -halfHeight / 2, geom: vertSegmentGeometry },
    // f: top-left vertical
    { x: -halfWidth, y: halfHeight / 2, geom: vertSegmentGeometry },
    // g: middle horizontal
    { x: 0, y: 0, geom: segmentGeometry },
  ];

  const pattern = SEVEN_SEGMENT_PATTERNS[digit];
  for (let i = 0; i < 7; i++) {
    const isOn = pattern[i] === 1;
    // Classic red-orange LED colour
    const material = new THREE.MeshStandardMaterial({
      color: isOn ? 0xff3300 : 0x1a0800,
      emissive: 0xff3300,
      emissiveIntensity: isOn ? 1.0 : 0.02,
      roughness: 0.3,
      metalness: 0.0,
      side: THREE.DoubleSide,
    });
    const segment = new THREE.Mesh(positions[i].geom.clone(), material);
    segment.position.set(positions[i].x, positions[i].y, 0.01);
    segment.userData = { segmentIndex: i, isOn };
    segments.push(segment);
    group.add(segment);
  }

  group.userData = { segments, digit };
  return group;
}

/**
 * Digital Twin visualisation of the neural network.
 *
 * Architecture: input[25] → dense → tanh → dense → softmax → output[10]
 *
 * The server broadcasts weight updates at ~30fps. This client:
 * - Owns the input state (user clicks on 5×5 grid)
 * - Calculates all activations locally using the received weights
 * - Renders the network with node intensities and edge colours based on activations
 *
 * Forward pass (matching the Axon model exactly):
 *   hidden = tanh(input @ dense_0)
 *   output = softmax(hidden @ dense_1)
 */
export const DigitalTwin = {
  mounted() {
    this.initScene();
    this.networkInitialized = false;
    this.animate();

    this.handleEvent("weights", (data) => {
      this.onWeightsReceived(data);
    });

    window.addEventListener("resize", () => this.onResize());
  },

  initScene() {
    const container = this.el;

    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x111111);

    this.camera = new THREE.PerspectiveCamera(
      60,
      container.clientWidth / container.clientHeight,
      0.1,
      1000,
    );
    this.camera.position.set(0, 0, 8);

    this.renderer = new THREE.WebGLRenderer({ antialias: true });
    this.renderer.setSize(container.clientWidth, container.clientHeight);
    this.renderer.setPixelRatio(window.devicePixelRatio);
    container.appendChild(this.renderer.domElement);

    this.controls = new OrbitControls(this.camera, this.renderer.domElement);
    this.controls.enableDamping = true;
    this.controls.dampingFactor = 0.05;

    const ambientLight = new THREE.AmbientLight(0xffffff, 0.4);
    this.scene.add(ambientLight);

    const directionalLight = new THREE.DirectionalLight(0xffffff, 0.8);
    directionalLight.position.set(5, 5, 5);
    this.scene.add(directionalLight);

    this.raycaster = new THREE.Raycaster();
    this.mouse = new THREE.Vector2();
    this.isDrawing = false;

    this.renderer.domElement.addEventListener("mousedown", (e) => {
      if (this.hitTestInput(e)) {
        this.isDrawing = true;
        this.controls.enabled = false;
        this.onDraw(e);
      }
    });
    this.renderer.domElement.addEventListener("mousemove", (e) => {
      if (this.isDrawing) this.onDraw(e);
    });
    this.renderer.domElement.addEventListener("mouseup", () => {
      this.isDrawing = false;
      this.controls.enabled = true;
    });
    this.renderer.domElement.addEventListener("mouseleave", () => {
      this.isDrawing = false;
      this.controls.enabled = true;
    });

    // Create HUD controls overlay
    this.createControls();

    // Default gamma value for wire brightness (2.2 is standard sRGB gamma)
    this.wireGamma = 2.2;
  },

  createControls() {
    this.el.style.position = "relative";

    const controlsContainer = document.createElement("div");
    controlsContainer.style.cssText = `
      position: absolute;
      top: 20px;
      left: 20px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      z-index: 100;
    `;

    // Reset button
    const button = document.createElement("button");
    button.textContent = "Reset";
    button.style.cssText = `
      padding: 10px 20px;
      background: #333;
      color: #fff;
      border: 1px solid #666;
      border-radius: 4px;
      cursor: pointer;
      font-size: 14px;
    `;
    button.addEventListener("click", () => this.resetInput());

    // Gamma slider container
    const sliderContainer = document.createElement("div");
    sliderContainer.style.cssText = `
      background: #333;
      padding: 10px;
      border: 1px solid #666;
      border-radius: 4px;
      color: #fff;
      font-size: 12px;
    `;

    const sliderLabel = document.createElement("label");
    sliderLabel.textContent = "Wire gamma: 2.2";
    sliderLabel.style.display = "block";
    sliderLabel.style.marginBottom = "5px";

    const slider = document.createElement("input");
    slider.type = "range";
    slider.min = "0.5";
    slider.max = "4.0";
    slider.step = "0.1";
    slider.value = "2.2";
    slider.style.width = "120px";
    slider.addEventListener("input", (e) => {
      this.wireGamma = parseFloat(e.target.value);
      sliderLabel.textContent = `Wire gamma: ${this.wireGamma.toFixed(1)}`;
      this.updateVisualisation();
    });

    sliderContainer.appendChild(sliderLabel);
    sliderContainer.appendChild(slider);

    controlsContainer.appendChild(button);
    controlsContainer.appendChild(sliderContainer);
    this.el.appendChild(controlsContainer);
  },

  initNetwork(topology) {
    this.inputSize = topology.input_size;
    this.hiddenSize = topology.hidden_size;
    this.outputSize = topology.output_size;

    // Client-owned input state (binary 0/1 for each pixel)
    this.inputState = new Array(this.inputSize).fill(0);

    // Current weights from server
    this.weights = { dense_0: null, dense_1: null };

    // Layer positions (x coordinates)
    this.layerX = { input: -4, hidden: 0, output: 4 };

    // Store mesh references
    this.nodes = { input: [], hidden: [], output: [] };
    this.edges = { inputToHidden: [], hiddenToOutput: [] };

    this.createNodes();
    this.createEdges();
  },

  createNodes() {
    // Input layer (5×5 grid of flat squares forming a drawing surface)
    const pixelSize = 0.45;
    const pixelGeometry = new THREE.PlaneGeometry(pixelSize, pixelSize);

    for (let i = 0; i < this.inputSize; i++) {
      const row = Math.floor(i / 5);
      const col = i % 5;
      const y = (2 - row) * 0.5;
      const z = (col - 2) * 0.5;

      const material = new THREE.MeshStandardMaterial({
        color: 0x4488ff,
        emissive: 0x4488ff,
        emissiveIntensity: 0.0,
        side: THREE.DoubleSide,
      });
      const node = new THREE.Mesh(pixelGeometry, material);
      node.position.set(this.layerX.input, y, z);
      node.rotation.y = Math.PI / 2; // Face the camera (rotate to YZ plane)
      node.userData = { layer: "input", index: i };
      this.scene.add(node);
      this.nodes.input.push(node);
    }

    const nodeGeometry = new THREE.SphereGeometry(0.15, 16, 16);

    // Hidden layer (arranged in rows of 3)
    for (let i = 0; i < this.hiddenSize; i++) {
      const row = Math.floor(i / 3);
      const col = i % 3;
      const y = (1 - row) * 0.6;
      const z = (col - 1) * 0.6;

      const material = new THREE.MeshStandardMaterial({
        color: 0x44ff88,
        emissive: 0x44ff88,
        emissiveIntensity: 0.1,
      });
      const node = new THREE.Mesh(nodeGeometry, material);
      node.position.set(this.layerX.hidden, y, z);
      node.userData = { layer: "hidden", index: i };
      this.scene.add(node);
      this.nodes.hidden.push(node);
    }

    // Output layer (7-segment displays arranged in a circle)
    const circleRadius = 1.2;
    for (let i = 0; i < this.outputSize; i++) {
      // Arrange in circle, starting from top (0 at top, going clockwise)
      const angle = (i / this.outputSize) * Math.PI * 2 - Math.PI / 2;
      const y = Math.sin(angle) * circleRadius;
      const z = Math.cos(angle) * circleRadius;

      const display = createSevenSegmentGroup(i, 0.35);
      display.position.set(this.layerX.output, y, z);
      display.rotation.y = Math.PI / 2;
      display.userData.layer = "output";
      display.userData.index = i;
      this.scene.add(display);
      this.nodes.output.push(display);
    }
  },

  createEdges() {
    // Input → hidden edges
    for (let i = 0; i < this.inputSize; i++) {
      for (let j = 0; j < this.hiddenSize; j++) {
        const edge = this.createEdge(
          this.nodes.input[i].position,
          this.nodes.hidden[j].position,
        );
        edge.userData = { fromLayer: "input", from: i, to: j };
        this.edges.inputToHidden.push(edge);
        this.scene.add(edge);
      }
    }

    // Hidden → output edges
    for (let i = 0; i < this.hiddenSize; i++) {
      for (let j = 0; j < this.outputSize; j++) {
        const edge = this.createEdge(
          this.nodes.hidden[i].position,
          this.nodes.output[j].position,
        );
        edge.userData = { fromLayer: "hidden", from: i, to: j };
        this.edges.hiddenToOutput.push(edge);
        this.scene.add(edge);
      }
    }
  },

  createEdge(from, to) {
    const geometry = new LineGeometry();
    geometry.setPositions([from.x, from.y, from.z, to.x, to.y, to.z]);

    const material = new LineMaterial({
      color: 0x444444,
      linewidth: 2,
      transparent: true,
      opacity: 0.3,
      resolution: new THREE.Vector2(window.innerWidth, window.innerHeight),
    });

    return new Line2(geometry, material);
  },

  onWeightsReceived(data) {
    const { weights, topology } = data;

    // Initialise network on first message
    if (!this.networkInitialized && topology) {
      this.initNetwork(topology);
      this.networkInitialized = true;
    }

    // Rebuild if topology changed
    if (topology && topology.hidden_size !== this.hiddenSize) {
      this.hiddenSize = topology.hidden_size;
      this.rebuildNetwork();
    }

    if (!this.networkInitialized) return;

    // Store new weights
    if (weights) {
      this.weights.dense_0 = weights.dense_0;
      this.weights.dense_1 = weights.dense_1;
    }

    // Recalculate and render
    this.updateVisualisation();
  },

  /**
   * Calculate forward pass and update visualisation.
   * Called when weights change or when user clicks input nodes.
   */
  updateVisualisation() {
    if (!this.weights.dense_0 || !this.weights.dense_1) return;

    // Forward pass: hidden = tanh(input @ dense_0)
    const hidden = this.forwardDense(
      this.inputState,
      this.weights.dense_0,
      this.inputSize,
      this.hiddenSize,
    ).map(Math.tanh);

    // Forward pass: output = softmax(hidden @ dense_1)
    const preOutput = this.forwardDense(
      hidden,
      this.weights.dense_1,
      this.hiddenSize,
      this.outputSize,
    );
    const output = this.softmax(preOutput);

    // Update node visuals
    this.updateNodeVisuals(this.inputState, hidden, output);

    // Update edge visuals
    this.updateEdgeVisuals(this.inputState, hidden);
  },

  /**
   * Matrix multiply: output[j] = sum_i(input[i] * weights[i * outSize + j])
   * Weights are stored row-major: [inSize, outSize]
   */
  forwardDense(input, weights, inSize, outSize) {
    const output = new Array(outSize).fill(0);
    for (let j = 0; j < outSize; j++) {
      for (let i = 0; i < inSize; i++) {
        output[j] += input[i] * weights[i * outSize + j];
      }
    }
    return output;
  },

  /**
   * Softmax: exp(x_i) / sum(exp(x_j))
   * With numerical stability: subtract max before exp
   */
  softmax(x) {
    const max = Math.max(...x);
    const exps = x.map((v) => Math.exp(v - max));
    const sum = exps.reduce((a, b) => a + b, 0);
    return exps.map((e) => e / sum);
  },

  updateNodeVisuals(input, hidden, output) {
    // Input pixels: intensity = input value (0 to 1, continuous)
    input.forEach((value, i) => {
      if (this.nodes.input[i]) {
        this.nodes.input[i].material.emissiveIntensity = value;
      }
    });

    // Hidden nodes: intensity = |tanh activation|
    hidden.forEach((value, i) => {
      if (this.nodes.hidden[i]) {
        this.nodes.hidden[i].material.emissiveIntensity = Math.abs(value) * 0.8;
      }
    });

    // Output nodes: 7-segment displays with brightness modulated by softmax probability
    output.forEach((activation, i) => {
      const display = this.nodes.output[i];
      if (!display || !display.userData.segments) return;

      const digit = display.userData.digit;
      const pattern = SEVEN_SEGMENT_PATTERNS[digit];

      display.userData.segments.forEach((segment, segIdx) => {
        const isOn = pattern[segIdx] === 1;
        if (isOn) {
          // "On" segments: brightness scales with activation
          const intensity = 0.15 + activation * 0.85;
          segment.material.emissiveIntensity = intensity;
          // Also brighten the base colour for more punch
          segment.material.color.setHex(activation > 0.3 ? 0xff3300 : 0x661400);
        } else {
          // "Off" segments stay very dim
          segment.material.emissiveIntensity = 0.02;
          segment.material.color.setHex(0x1a0800);
        }
      });
    });
  },

  updateEdgeVisuals(input, hidden) {
    // Input → hidden edges: activation = input[i] * weight[i,j]
    let edgeIdx = 0;
    for (let i = 0; i < this.inputSize; i++) {
      for (let j = 0; j < this.hiddenSize; j++) {
        const weight = this.weights.dense_0[i * this.hiddenSize + j];
        const activation = input[i] * weight;
        this.setEdgeAppearance(this.edges.inputToHidden[edgeIdx], activation);
        edgeIdx++;
      }
    }

    // Hidden → output edges: activation = hidden[i] * weight[i,j]
    edgeIdx = 0;
    for (let i = 0; i < this.hiddenSize; i++) {
      for (let j = 0; j < this.outputSize; j++) {
        const weight = this.weights.dense_1[i * this.outputSize + j];
        const activation = hidden[i] * weight;
        this.setEdgeAppearance(this.edges.hiddenToOutput[edgeIdx], activation);
        edgeIdx++;
      }
    }
  },

  setEdgeAppearance(edge, activation) {
    if (!edge) return;

    // Normalise activation to 0-1 range (clamp at magnitude 2)
    const absActivation = Math.min(Math.abs(activation), 2) / 2;

    // Apply gamma correction: perceived = actual^(1/gamma)
    // Higher gamma = darker wires (need more activation to appear bright)
    // This makes perceived brightness roughly linear with activation value
    const gamma = this.wireGamma || 2.2;
    const corrected = Math.pow(absActivation, 1 / gamma);

    if (Math.abs(activation) < 0.001) {
      // Inactive: dim grey, thin
      edge.material.color.setHex(0x444444);
      edge.material.opacity = 0.05;
      edge.material.linewidth = 1;
    } else if (activation >= 0) {
      // Positive: green, brightness and thickness based on gamma-corrected magnitude
      edge.material.color.setHex(0x44ff44);
      edge.material.opacity = 0.1 + corrected * 0.5;
      edge.material.linewidth = 1 + corrected * 4;
    } else {
      // Negative: red, brightness and thickness based on gamma-corrected magnitude
      edge.material.color.setHex(0xff4444);
      edge.material.opacity = 0.1 + corrected * 0.5;
      edge.material.linewidth = 1 + corrected * 4;
    }
  },

  rebuildNetwork() {
    // Remove existing hidden nodes and all edges
    this.nodes.hidden.forEach((n) => this.scene.remove(n));
    this.edges.inputToHidden.forEach((e) => this.scene.remove(e));
    this.edges.hiddenToOutput.forEach((e) => this.scene.remove(e));

    this.nodes.hidden = [];
    this.edges.inputToHidden = [];
    this.edges.hiddenToOutput = [];

    // Recreate hidden nodes
    const nodeGeometry = new THREE.SphereGeometry(0.15, 16, 16);
    for (let i = 0; i < this.hiddenSize; i++) {
      const row = Math.floor(i / 3);
      const col = i % 3;
      const y = (1 - row) * 0.6;
      const z = (col - 1) * 0.6;

      const material = new THREE.MeshStandardMaterial({
        color: 0x44ff88,
        emissive: 0x44ff88,
        emissiveIntensity: 0.1,
      });
      const node = new THREE.Mesh(nodeGeometry, material);
      node.position.set(this.layerX.hidden, y, z);
      node.userData = { layer: "hidden", index: i };
      this.scene.add(node);
      this.nodes.hidden.push(node);
    }

    // Recreate edges
    for (let i = 0; i < this.inputSize; i++) {
      for (let j = 0; j < this.hiddenSize; j++) {
        const edge = this.createEdge(
          this.nodes.input[i].position,
          this.nodes.hidden[j].position,
        );
        edge.userData = { fromLayer: "input", from: i, to: j };
        this.edges.inputToHidden.push(edge);
        this.scene.add(edge);
      }
    }

    for (let i = 0; i < this.hiddenSize; i++) {
      for (let j = 0; j < this.outputSize; j++) {
        const edge = this.createEdge(
          this.nodes.hidden[i].position,
          this.nodes.output[j].position,
        );
        edge.userData = { fromLayer: "hidden", from: i, to: j };
        this.edges.hiddenToOutput.push(edge);
        this.scene.add(edge);
      }
    }
  },

  resetInput() {
    if (!this.networkInitialized) return;
    this.inputState.fill(0);
    this.updateVisualisation();
  },

  hitTestInput(event) {
    if (!this.networkInitialized) return false;

    const rect = this.renderer.domElement.getBoundingClientRect();
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;

    this.raycaster.setFromCamera(this.mouse, this.camera);
    const intersects = this.raycaster.intersectObjects(this.nodes.input);
    return intersects.length > 0;
  },

  onDraw(event) {
    if (!this.networkInitialized) return;

    const rect = this.renderer.domElement.getBoundingClientRect();
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;

    this.raycaster.setFromCamera(this.mouse, this.camera);
    const intersects = this.raycaster.intersectObjects(this.nodes.input);

    if (intersects.length > 0) {
      const node = intersects[0].object;
      const index = node.userData.index;

      // Gradually increase activation (0 to 1) while drawing
      const increment = 0.15;
      this.inputState[index] = Math.min(1, this.inputState[index] + increment);

      // Recalculate and update visualisation
      this.updateVisualisation();
    }
  },

  onResize() {
    const container = this.el;
    this.camera.aspect = container.clientWidth / container.clientHeight;
    this.camera.updateProjectionMatrix();
    this.renderer.setSize(container.clientWidth, container.clientHeight);

    // Update line material resolutions
    const resolution = new THREE.Vector2(
      container.clientWidth,
      container.clientHeight,
    );
    [...this.edges.inputToHidden, ...this.edges.hiddenToOutput].forEach(
      (edge) => {
        if (edge?.material?.resolution) {
          edge.material.resolution.copy(resolution);
        }
      },
    );
  },

  animate() {
    requestAnimationFrame(() => this.animate());
    this.controls.update();
    this.renderer.render(this.scene, this.camera);
  },
};
