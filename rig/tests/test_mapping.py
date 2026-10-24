from pathlib import Path

import numpy as np
from conftest import CHIPS, MakeRig
from sim import layout

from neon_rig.experiments import crowded, map_leds
from neon_rig.leds import LedMap


def test_every_populated_channel_is_found_where_it_is(led_map: LedMap) -> None:
    leds, colours = layout(CHIPS)
    populated = {led.key: led.position for led in leds}

    assert {region.key for region in led_map.present()} == set(populated)
    assert len(led_map.regions) == sum(CHIPS.values()) * 24
    for region in led_map.present():
        assert region.centroid is not None
        x, y = populated[region.key]
        assert abs(region.centroid[0] - x) < 1.0, region.label
        assert abs(region.centroid[1] - y) < 1.0, region.label
        assert region.colour == colours[region.key], region.label
        assert region.saturated_px == 0


def test_a_map_survives_saving_and_loading(led_map: LedMap, tmp_path: Path) -> None:
    led_map.save(tmp_path)
    loaded = LedMap.load(tmp_path)

    assert loaded.regions == led_map.regions
    assert loaded.shape == led_map.shape
    for key, (indices, weights) in led_map.masks.items():
        np.testing.assert_array_equal(loaded.masks[key][0], indices)
        np.testing.assert_array_equal(loaded.masks[key][1], weights)
    np.testing.assert_array_equal(loaded.dark, led_map.dark)


def test_a_bright_steady_patch_isnt_taken_for_an_led(make_rig: MakeRig) -> None:
    # A status LED or a screen, away from the installation's LEDs and brighter
    # than the dark frame around it.
    rig, _ = make_rig(camera={"glow": (130, 60, 6, 0.08)})
    leds, _ = layout(CHIPS)

    led_map, _ = map_leds(rig)

    assert {region.key for region in led_map.present()} == {led.key for led in leds}
    assert crowded(led_map) == []
