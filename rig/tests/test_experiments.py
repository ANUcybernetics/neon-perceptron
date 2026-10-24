import polars as pl
import pytest
from conftest import MakeRig

from neon_rig.experiments import blank_search, calibrate, flicker_suite
from neon_rig.leds import LedMap


def value(summary: pl.DataFrame, condition: str, chain: str, column: str) -> float:
    row = summary.filter(
        (pl.col("condition") == condition) & (pl.col("chain") == chain)
    )
    return row[column].item()


def rms_vs_static(summary: pl.DataFrame, condition: str, chain: str) -> float:
    return value(summary, condition, chain, "rms_vs_static")


def test_relatching_flickers_and_reshifting_does_not(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig()

    result = flicker_suite(rig, led_map, level=4095, seconds=6, warmup_s=1)

    assert set(result.summary["condition"]) == {
        "static",
        "relatch 30 Hz",
        "relatch 10 Hz",
        "reshift 30 Hz",
    }
    for chain in ("input_left", "main"):
        assert rms_vs_static(result.summary, "relatch 30 Hz", chain) > 3
        assert rms_vs_static(result.summary, "relatch 10 Hz", chain) > 3
        assert rms_vs_static(result.summary, "reshift 30 Hz", chain) < 1.5
        # Each latch costs light, so latching three times as often costs more.
        loss_30 = value(result.summary, "relatch 30 Hz", chain, "mean_vs_static")
        loss_10 = value(result.summary, "relatch 10 Hz", chain, "mean_vs_static")
        assert loss_30 < loss_10 < 0.999


def test_a_floating_blank_line_shows_up_when_reshifting(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig(floating_blank=frozenset({"main"}))

    result = flicker_suite(rig, led_map, level=4095, seconds=6, warmup_s=1)

    assert rms_vs_static(result.summary, "reshift 30 Hz", "main") > 3
    assert rms_vs_static(result.summary, "reshift 30 Hz", "input_left") < 1.5
    reshift = result.summary.filter(pl.col("condition") == "reshift 30 Hz")
    losses = dict(zip(reshift["chain"], reshift["mean_vs_static"], strict=True))
    assert losses["main"] < 0.99 < losses["input_left"]


def test_pulsing_blank_around_xlat_removes_the_latch_flicker(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, site = make_rig()
    for chain in site.chips:
        rig.pi.configure(chain, blank_gpio="GPIO17", blank_pulse=True)

    result = flicker_suite(rig, led_map, level=4095, seconds=6, warmup_s=1)

    for chain in ("input_left", "main"):
        assert rms_vs_static(result.summary, "relatch 30 Hz, BLANK pulsed", chain) < 1.5


def test_a_one_percent_wobble_stands_out_from_the_noise(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig()

    result = calibrate(
        rig, led_map, level=4000, depth=0.01, freq_hz=5.0, seconds=20, warmup_s=1
    )

    assert result.detected
    assert 0.75 < result.residual < 1.3
    assert result.floor_rms_median < 0.005


def test_latching_that_aliases_onto_the_wobble_isnt_detected(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    # At 25 fps, latching at 30 Hz could alias onto 5 Hz; the steady run
    # latches just like the wobble, so it would show there too.
    rig, _ = make_rig(camera={"fps": 25.0})

    tiny = calibrate(rig, led_map, depth=0.0001, seconds=20, warmup_s=1)
    real = calibrate(rig, led_map, depth=0.01, seconds=20, warmup_s=1)

    assert not tiny.detected
    assert real.detected
    assert abs(real.fps - 25.0) < 0.01


def test_blank_search_finds_each_chains_blank_gpio(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig(blank_wiring={"main": "GPIO17", "input_left": "GPIO22"})

    found, ratios = blank_search(rig, led_map)

    assert found == {"main": "GPIO17", "input_left": "GPIO22"}
    assert ratios["GPIO24"]["main"]["high"] > 0.9


def test_bracketing_static_captures_cancel_warm_up_drift(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig(droop=0.03, droop_tau_s=30.0)

    result = flicker_suite(rig, led_map, level=4095, seconds=6, warmup_s=1)

    for chain in ("input_left", "main"):
        assert (
            abs(value(result.summary, "reshift 30 Hz", chain, "mean_vs_static") - 1)
            < 0.003
        )


def test_blank_pulsing_runs_on_the_chains_that_have_blank(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig()
    rig.pi.configure("input_left", blank_gpio="GPIO22", blank_pulse=True)

    result = flicker_suite(rig, led_map, level=4095, seconds=6, warmup_s=1)

    pulsed = result.summary.filter(pl.col("condition") == "relatch 30 Hz, BLANK pulsed")
    assert pulsed["chain"].to_list() == ["input_left"]
    assert pulsed["rms_vs_static"].item() < 1.5


def test_a_scene_that_saturates_everywhere_is_refused(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig(brightness=20.0)

    with pytest.raises(RuntimeError, match="every region saturates"):
        flicker_suite(rig, led_map, level=4095, seconds=2, warmup_s=0)


def test_a_map_with_nothing_lit_is_refused(make_rig: MakeRig, led_map: LedMap) -> None:
    rig, _ = make_rig()
    empty = LedMap(
        led_map.shape,
        led_map.level,
        [region.model_copy(update={"present": False}) for region in led_map.regions],
        {},
        led_map.dark,
    )

    with pytest.raises(RuntimeError, match="no lit regions"):
        flicker_suite(rig, empty, seconds=2, warmup_s=0)
