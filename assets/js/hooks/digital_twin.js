import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { Line2 } from "three/addons/lines/Line2.js";
import { LineMaterial } from "three/addons/lines/LineMaterial.js";
import { LineGeometry } from "three/addons/lines/LineGeometry.js";

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
    this.renderer.domElement.addEventListener("click", (e) => this.onClick(e));
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
    const nodeGeometry = new THREE.SphereGeometry(0.15, 16, 16);

    // Input layer (5×5 grid)
    for (let i = 0; i < this.inputSize; i++) {
      const row = Math.floor(i / 5);
      const col = i % 5;
      const y = (2 - row) * 0.5;
      const z = (col - 2) * 0.5;

      const material = new THREE.MeshStandardMaterial({
        color: 0x4488ff,
        emissive: 0x4488ff,
        emissiveIntensity: 0.1,
      });
      const node = new THREE.Mesh(nodeGeometry, material);
      node.position.set(this.layerX.input, y, z);
      node.userData = { layer: "input", index: i };
      this.scene.add(node);
      this.nodes.input.push(node);
    }

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

    // Output layer (vertical line, labelled 0-9)
    for (let i = 0; i < this.outputSize; i++) {
      const y = ((this.outputSize - 1) / 2 - i) * 0.5;

      const material = new THREE.MeshStandardMaterial({
        color: 0xff8844,
        emissive: 0xff8844,
        emissiveIntensity: 0.1,
      });
      const node = new THREE.Mesh(nodeGeometry, material);
      node.position.set(this.layerX.output, y, 0);
      node.userData = { layer: "output", index: i };
      this.scene.add(node);
      this.nodes.output.push(node);
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
    // Input nodes: intensity = input value (0 or 1)
    input.forEach((value, i) => {
      if (this.nodes.input[i]) {
        this.nodes.input[i].material.emissiveIntensity = value * 0.8;
      }
    });

    // Hidden nodes: intensity = |tanh activation|
    hidden.forEach((value, i) => {
      if (this.nodes.hidden[i]) {
        this.nodes.hidden[i].material.emissiveIntensity = Math.abs(value) * 0.8;
      }
    });

    // Output nodes: intensity = softmax probability
    output.forEach((value, i) => {
      if (this.nodes.output[i]) {
        this.nodes.output[i].material.emissiveIntensity = value * 0.8;
      }
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

    const absActivation = Math.min(Math.abs(activation), 2) / 2;

    if (Math.abs(activation) < 0.001) {
      // Inactive: dim grey, thin
      edge.material.color.setHex(0x444444);
      edge.material.opacity = 0.1;
      edge.material.linewidth = 1;
    } else if (activation >= 0) {
      // Positive: green, brightness and thickness based on magnitude
      edge.material.color.setHex(0x44ff44);
      edge.material.opacity = 0.3 + absActivation * 0.7;
      edge.material.linewidth = 1 + absActivation * 4;
    } else {
      // Negative: red, brightness and thickness based on magnitude
      edge.material.color.setHex(0xff4444);
      edge.material.opacity = 0.3 + absActivation * 0.7;
      edge.material.linewidth = 1 + absActivation * 4;
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

  onClick(event) {
    if (!this.networkInitialized) return;

    const rect = this.renderer.domElement.getBoundingClientRect();
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1;
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1;

    this.raycaster.setFromCamera(this.mouse, this.camera);
    const intersects = this.raycaster.intersectObjects(this.nodes.input);

    if (intersects.length > 0) {
      const node = intersects[0].object;
      const index = node.userData.index;

      // Toggle input state (client-side only)
      this.inputState[index] = this.inputState[index] === 0 ? 1 : 0;

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
