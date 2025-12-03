import * as THREE from "three"
import { OrbitControls } from "three/addons/controls/OrbitControls.js"

export const DigitalTwin = {
  mounted() {
    this.initScene()
    this.initNetwork()
    this.animate()

    this.handleEvent("activations", (data) => {
      this.updateActivations(data)
    })

    window.addEventListener("resize", () => this.onResize())
  },

  initScene() {
    const container = this.el

    this.scene = new THREE.Scene()
    this.scene.background = new THREE.Color(0x111111)

    this.camera = new THREE.PerspectiveCamera(
      60,
      container.clientWidth / container.clientHeight,
      0.1,
      1000
    )
    this.camera.position.set(0, 0, 8)

    this.renderer = new THREE.WebGLRenderer({ antialias: true })
    this.renderer.setSize(container.clientWidth, container.clientHeight)
    this.renderer.setPixelRatio(window.devicePixelRatio)
    container.appendChild(this.renderer.domElement)

    this.controls = new OrbitControls(this.camera, this.renderer.domElement)
    this.controls.enableDamping = true
    this.controls.dampingFactor = 0.05

    const ambientLight = new THREE.AmbientLight(0xffffff, 0.4)
    this.scene.add(ambientLight)

    const directionalLight = new THREE.DirectionalLight(0xffffff, 0.8)
    directionalLight.position.set(5, 5, 5)
    this.scene.add(directionalLight)

    // For raycasting (click detection)
    this.raycaster = new THREE.Raycaster()
    this.mouse = new THREE.Vector2()
    this.renderer.domElement.addEventListener("click", (e) => this.onClick(e))
  },

  initNetwork() {
    // Network topology: 25 inputs (5x5 grid) -> hidden -> 10 outputs
    // Hidden size will come from the server, default to 8 for now
    this.inputSize = 25
    this.hiddenSize = 8
    this.outputSize = 10

    // User-controlled input state (5x5 grid)
    this.inputState = new Array(25).fill(0)

    // Layer positions (x coordinates)
    this.layerX = { input: -4, hidden: 0, output: 4 }

    // Store mesh references
    this.nodes = { input: [], hidden: [], output: [] }
    this.edges = { inputToHidden: [], hiddenToOutput: [] }

    this.createNodes()
    this.createEdges()
  },

  createNodes() {
    const nodeGeometry = new THREE.SphereGeometry(0.15, 16, 16)

    // Input layer (5x5 grid arrangement)
    for (let i = 0; i < this.inputSize; i++) {
      const row = Math.floor(i / 5)
      const col = i % 5
      const y = (2 - row) * 0.5
      const z = (col - 2) * 0.5

      const material = new THREE.MeshStandardMaterial({
        color: 0x4488ff,
        emissive: 0x4488ff,
        emissiveIntensity: 0.1
      })
      const node = new THREE.Mesh(nodeGeometry, material)
      node.position.set(this.layerX.input, y, z)
      node.userData = { layer: "input", index: i }
      this.scene.add(node)
      this.nodes.input.push(node)
    }

    // Hidden layer (vertical line)
    for (let i = 0; i < this.hiddenSize; i++) {
      const y = ((this.hiddenSize - 1) / 2 - i) * 0.6

      const material = new THREE.MeshStandardMaterial({
        color: 0x44ff88,
        emissive: 0x44ff88,
        emissiveIntensity: 0.1
      })
      const node = new THREE.Mesh(nodeGeometry, material)
      node.position.set(this.layerX.hidden, y, 0)
      node.userData = { layer: "hidden", index: i }
      this.scene.add(node)
      this.nodes.hidden.push(node)
    }

    // Output layer (vertical line)
    for (let i = 0; i < this.outputSize; i++) {
      const y = ((this.outputSize - 1) / 2 - i) * 0.5

      const material = new THREE.MeshStandardMaterial({
        color: 0xff8844,
        emissive: 0xff8844,
        emissiveIntensity: 0.1
      })
      const node = new THREE.Mesh(nodeGeometry, material)
      node.position.set(this.layerX.output, y, 0)
      node.userData = { layer: "output", index: i }
      this.scene.add(node)
      this.nodes.output.push(node)
    }
  },

  createEdges() {
    // Input to hidden edges
    for (let i = 0; i < this.inputSize; i++) {
      for (let j = 0; j < this.hiddenSize; j++) {
        const edge = this.createEdge(
          this.nodes.input[i].position,
          this.nodes.hidden[j].position
        )
        edge.userData = { fromLayer: "input", from: i, to: j }
        this.edges.inputToHidden.push(edge)
        this.scene.add(edge)
      }
    }

    // Hidden to output edges
    for (let i = 0; i < this.hiddenSize; i++) {
      for (let j = 0; j < this.outputSize; j++) {
        const edge = this.createEdge(
          this.nodes.hidden[i].position,
          this.nodes.output[j].position
        )
        edge.userData = { fromLayer: "hidden", from: i, to: j }
        this.edges.hiddenToOutput.push(edge)
        this.scene.add(edge)
      }
    }
  },

  createEdge(from, to) {
    const points = [from.clone(), to.clone()]
    const geometry = new THREE.BufferGeometry().setFromPoints(points)
    const material = new THREE.LineBasicMaterial({
      color: 0x444444,
      transparent: true,
      opacity: 0.3
    })
    return new THREE.Line(geometry, material)
  },

  updateActivations(data) {
    const { activations, weights, topology } = data

    // Update topology if changed
    if (topology && topology.hidden_size !== this.hiddenSize) {
      this.hiddenSize = topology.hidden_size
      this.rebuildNetwork()
    }

    // Update input nodes
    if (activations.input) {
      activations.input.forEach((value, i) => {
        if (this.nodes.input[i]) {
          const intensity = Math.abs(value)
          this.nodes.input[i].material.emissiveIntensity = intensity * 0.8
        }
      })
    }

    // Update hidden nodes
    if (activations.hidden_0) {
      activations.hidden_0.forEach((value, i) => {
        if (this.nodes.hidden[i]) {
          const intensity = Math.abs(value)
          this.nodes.hidden[i].material.emissiveIntensity = intensity * 0.8
        }
      })
    }

    // Update output nodes
    if (activations.output) {
      activations.output.forEach((value, i) => {
        if (this.nodes.output[i]) {
          const intensity = Math.abs(value)
          this.nodes.output[i].material.emissiveIntensity = intensity * 0.8
        }
      })
    }

    // Update edge colours based on weights
    if (weights) {
      this.updateEdgeWeights(weights)
    }
  },

  updateEdgeWeights(weights) {
    // weights.dense_0: [input_size, hidden_size]
    // weights.dense_1: [hidden_size, output_size]

    if (weights.dense_0) {
      const w0 = weights.dense_0
      let edgeIdx = 0
      for (let i = 0; i < this.inputSize; i++) {
        for (let j = 0; j < this.hiddenSize; j++) {
          const weight = w0[i * this.hiddenSize + j] || 0
          this.setEdgeAppearance(this.edges.inputToHidden[edgeIdx], weight)
          edgeIdx++
        }
      }
    }

    if (weights.dense_1) {
      const w1 = weights.dense_1
      let edgeIdx = 0
      for (let i = 0; i < this.hiddenSize; i++) {
        for (let j = 0; j < this.outputSize; j++) {
          const weight = w1[i * this.outputSize + j] || 0
          this.setEdgeAppearance(this.edges.hiddenToOutput[edgeIdx], weight)
          edgeIdx++
        }
      }
    }
  },

  setEdgeAppearance(edge, weight) {
    if (!edge) return

    const absWeight = Math.min(Math.abs(weight), 2) / 2
    const isPositive = weight >= 0

    // Green for positive, red for negative
    const color = isPositive ? new THREE.Color(0x44ff44) : new THREE.Color(0xff4444)

    edge.material.color = color
    edge.material.opacity = 0.1 + absWeight * 0.6
  },

  rebuildNetwork() {
    // Remove existing nodes and edges
    this.nodes.hidden.forEach((n) => this.scene.remove(n))
    this.edges.inputToHidden.forEach((e) => this.scene.remove(e))
    this.edges.hiddenToOutput.forEach((e) => this.scene.remove(e))

    this.nodes.hidden = []
    this.edges.inputToHidden = []
    this.edges.hiddenToOutput = []

    // Recreate hidden nodes
    const nodeGeometry = new THREE.SphereGeometry(0.15, 16, 16)
    for (let i = 0; i < this.hiddenSize; i++) {
      const y = ((this.hiddenSize - 1) / 2 - i) * 0.6

      const material = new THREE.MeshStandardMaterial({
        color: 0x44ff88,
        emissive: 0x44ff88,
        emissiveIntensity: 0.1
      })
      const node = new THREE.Mesh(nodeGeometry, material)
      node.position.set(this.layerX.hidden, y, 0)
      node.userData = { layer: "hidden", index: i }
      this.scene.add(node)
      this.nodes.hidden.push(node)
    }

    // Recreate edges
    for (let i = 0; i < this.inputSize; i++) {
      for (let j = 0; j < this.hiddenSize; j++) {
        const edge = this.createEdge(
          this.nodes.input[i].position,
          this.nodes.hidden[j].position
        )
        edge.userData = { fromLayer: "input", from: i, to: j }
        this.edges.inputToHidden.push(edge)
        this.scene.add(edge)
      }
    }

    for (let i = 0; i < this.hiddenSize; i++) {
      for (let j = 0; j < this.outputSize; j++) {
        const edge = this.createEdge(
          this.nodes.hidden[i].position,
          this.nodes.output[j].position
        )
        edge.userData = { fromLayer: "hidden", from: i, to: j }
        this.edges.hiddenToOutput.push(edge)
        this.scene.add(edge)
      }
    }
  },

  onClick(event) {
    const rect = this.renderer.domElement.getBoundingClientRect()
    this.mouse.x = ((event.clientX - rect.left) / rect.width) * 2 - 1
    this.mouse.y = -((event.clientY - rect.top) / rect.height) * 2 + 1

    this.raycaster.setFromCamera(this.mouse, this.camera)
    const intersects = this.raycaster.intersectObjects(this.nodes.input)

    if (intersects.length > 0) {
      const node = intersects[0].object
      const index = node.userData.index

      // Toggle input state
      this.inputState[index] = this.inputState[index] === 0 ? 1 : 0

      // Update visual
      const value = this.inputState[index]
      node.material.emissiveIntensity = value * 0.8

      // Send to server
      this.pushEvent("set_input", { input: this.inputState })
    }
  },

  onResize() {
    const container = this.el
    this.camera.aspect = container.clientWidth / container.clientHeight
    this.camera.updateProjectionMatrix()
    this.renderer.setSize(container.clientWidth, container.clientHeight)
  },

  animate() {
    requestAnimationFrame(() => this.animate())
    this.controls.update()
    this.renderer.render(this.scene, this.camera)
  }
}
