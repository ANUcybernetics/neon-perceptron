defmodule NeonPerceptron.ApplicationTest do
  use ExUnit.Case, async: false

  alias NeonPerceptron.{Chain, NetworkState}

  test "the running build's chains receive network state broadcasts" do
    build = Application.fetch_env!(:neon_perceptron, :build)
    state = NetworkState.null(build.topology())

    for %{id: id} <- build.chain_configs() do
      before = Chain.status(id).counts

      Phoenix.PubSub.broadcast(NeonPerceptron.PubSub, "network_state", {:network_state, state})

      after_broadcast = Chain.status(id).counts

      assert after_broadcast.requested + after_broadcast.ignored >
               before.requested + before.ignored
    end
  end
end
