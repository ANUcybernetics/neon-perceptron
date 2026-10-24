import polars as pl
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

    result = flicker_suite(rig, led_map, level=4095, seconds=6)

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

    result = flicker_suite(rig, led_map, level=4095, seconds=6)

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

    result = flicker_suite(rig, led_map, level=4095, seconds=6)

    for chain in ("input_left", "main"):
        assert rms_vs_static(result.summary, "relatch 30 Hz, BLANK pulsed", chain) < 1.5


def test_a_one_percent_wobble_stands_out_from_the_noise(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig()

    result = calibrate(rig, led_map, level=4000, depth=0.01, freq_hz=5.0, seconds=10)

    assert result.detected
    assert 0.8 < result.gain < 1.2
    assert result.floor_rms_median < 0.005


def test_blank_search_finds_each_chains_blank_gpio(
    make_rig: MakeRig, led_map: LedMap
) -> None:
    rig, _ = make_rig(blank_wiring={"main": "GPIO17", "input_left": "GPIO22"})

    found, ratios = blank_search(rig, led_map)

    assert found == {"main": "GPIO17", "input_left": "GPIO22"}
    assert ratios["GPIO24"]["main"]["high"] > 0.9
