defmodule NeonPerceptronWeb.ErrorHTML do
  @moduledoc """
  Error pages for the web interface.
  """
  use NeonPerceptronWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
