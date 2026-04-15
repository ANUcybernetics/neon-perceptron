# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware,
  rootfs_overlay: "rootfs_overlay"

case Mix.target() do
  :reterminal_dm ->
    config :nerves, :firmware, fwup_conf: "config/reterminal_dm/fwup.conf"

  :rpi4 ->
    # Stock nerves_system_rpi4 hardcodes config.txt to its system default,
    # and does not bundle the spi0-1cs / spi1-1cs overlays we need to drive
    # TLC5947 chains. Override both by using our own fwup.conf.
    config :nerves, :firmware, fwup_conf: "config/rpi4/fwup.conf"

  _ ->
    :ok
end

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1731026676"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
