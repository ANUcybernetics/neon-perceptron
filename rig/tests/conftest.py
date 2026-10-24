from collections.abc import Callable
from typing import Any

import pytest
from sim import Installation, SimCamera, SimClock, SimPi, layout

from neon_rig.experiments import Rig, map_leds
from neon_rig.leds import LedMap

CHIPS = {"input_left": 2, "main": 3}

type MakeRig = Callable[..., tuple[Rig, Installation]]


@pytest.fixture
def make_rig() -> MakeRig:
    """A rig on a simulated installation; keyword arguments go to it."""

    def make(**options: Any) -> tuple[Rig, Installation]:
        clock = SimClock()
        leds, _ = layout(CHIPS)
        site = Installation(chips=CHIPS, leds=leds, **options)
        return Rig(SimPi(site, clock), SimCamera(site, clock), clock), site

    return make


@pytest.fixture(scope="session")
def led_map() -> LedMap:
    """A map of the simulated installation, made once per test worker."""
    clock = SimClock()
    leds, _ = layout(CHIPS)
    site = Installation(chips=CHIPS, leds=leds)
    led_map, _ = map_leds(Rig(SimPi(site, clock), SimCamera(site, clock), clock))
    return led_map
