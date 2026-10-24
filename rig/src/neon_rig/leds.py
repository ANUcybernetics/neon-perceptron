"""Where each LED channel shows up in the camera image.

Mapping lights one channel at a time and compares the image with a dark one.
The difference, in linear light, gives the channel's region and a weight per
pixel, so a later brightness reading of that channel is a weighted sum over
its region. Regions of channels on the same LED (an RGB LED's three dies)
overlap, which is fine: each reading only ever asks about one channel's
light.
"""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Self, cast

import cv2
import numpy as np
from pydantic import BaseModel, ConfigDict

type Key = tuple[str, int, int]


def linear_lut(gamma: float) -> np.ndarray:
    """Lookup from 8-bit camera values to linear light (0--1)."""
    return ((np.arange(256) / 255.0) ** gamma).astype(np.float32)


def luminance(frame: np.ndarray, lut: np.ndarray) -> np.ndarray:
    """Linear light per pixel, summed over the colour channels."""
    return lut[frame].sum(axis=2)


class Region(BaseModel):
    model_config = ConfigDict(frozen=True)

    chain: str
    chip: int
    channel: int
    present: bool
    peak: float
    snr: float
    area_px: int = 0
    centroid: tuple[float, float] | None = None
    bbox: tuple[int, int, int, int] | None = None
    colour: str | None = None
    bgr: tuple[float, float, float] | None = None
    saturated_px: int = 0

    @property
    def key(self) -> Key:
        return (self.chain, self.chip, self.channel)

    @property
    def label(self) -> str:
        return f"{self.chain}/{self.chip}/{self.channel}"


def colour_name(bgr: tuple[float, float, float]) -> str:
    """Rough colour of a channel's light from its mean linear BGR."""
    names = ("blue", "green", "red")
    order = sorted(range(3), key=lambda i: bgr[i], reverse=True)
    top, second = bgr[order[0]], bgr[order[1]]
    if second > 0.6 * top and bgr[order[2]] > 0.4 * top:
        return "white"
    if second > 0.6 * top:
        return f"{names[order[0]]}-{names[order[1]]}"
    return names[order[0]]


def locate(
    key: Key,
    lit: np.ndarray,
    dark: np.ndarray,
    noise: float,
    lit_max: np.ndarray,
    min_snr: float = 8.0,
    keep_fraction: float = 0.2,
) -> tuple[Region, tuple[np.ndarray, np.ndarray] | None]:
    """Find the region one lit channel adds to the image.

    `lit` and `dark` are mean linear BGR images, `noise` the standard
    deviation of one pixel of a mean luminance image, and `lit_max` the raw
    per-pixel maximum over the lit frames (for spotting saturation). Pixels
    above `keep_fraction` of the peak, in connected pieces that themselves
    reach half the peak, form the region. Returns the region and its mask as
    flat pixel indices with weights summing to one, or no mask if the channel
    didn't light anything above `min_snr` times the noise.
    """
    chain, chip, channel = key
    diff = lit - dark
    lum = cv2.GaussianBlur(diff.sum(axis=2), (3, 3), 0)
    peak = float(lum.max())
    snr = peak / noise if noise > 0 else float("inf")
    if snr < min_snr:
        return Region(
            chain=chain, chip=chip, channel=channel, present=False, peak=peak, snr=snr
        ), None

    above = (lum >= keep_fraction * peak).astype(np.uint8)
    count, labels = cv2.connectedComponents(above, connectivity=8)
    keep = np.zeros_like(above, dtype=bool)
    for label in range(1, count):
        piece = labels == label
        if lum[piece].max() >= 0.5 * peak:
            keep |= piece

    weights = np.where(keep, lum, 0.0)
    indices = np.flatnonzero(weights)
    values = weights.ravel()[indices]
    values = (values / values.sum()).astype(np.float32)

    ys, xs = np.nonzero(keep)
    bgr = diff[keep].sum(axis=0)
    bgr = bgr / bgr.max()
    region = Region(
        chain=chain,
        chip=chip,
        channel=channel,
        present=True,
        peak=peak,
        snr=snr,
        area_px=int(keep.sum()),
        centroid=(
            float(np.average(xs, weights=lum[keep])),
            float(np.average(ys, weights=lum[keep])),
        ),
        bbox=(int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())),
        colour=colour_name((float(bgr[0]), float(bgr[1]), float(bgr[2]))),
        bgr=(float(bgr[0]), float(bgr[1]), float(bgr[2])),
        saturated_px=int((lit_max[keep] >= 250).any(axis=1).sum()),
    )
    return region, (indices.astype(np.int64), values)


@dataclass
class LedMap:
    """Every mapped channel, with masks for the ones that lit something, and
    the mean dark image in linear BGR."""

    shape: tuple[int, int]
    level: int
    regions: list[Region]
    masks: dict[Key, tuple[np.ndarray, np.ndarray]]
    dark: np.ndarray

    def present(self) -> list[Region]:
        return [region for region in self.regions if region.present]

    def save(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        meta = {
            "shape": list(self.shape),
            "level": self.level,
            "regions": [region.model_dump() for region in self.regions],
        }
        (directory / "map.json").write_text(json.dumps(meta, indent=2))
        arrays = {"dark": self.dark}
        for (chain, chip, channel), (indices, weights) in self.masks.items():
            arrays[f"{chain}/{chip}/{channel}/indices"] = indices
            arrays[f"{chain}/{chip}/{channel}/weights"] = weights
        np.savez_compressed(directory / "masks.npz", **cast(Any, arrays))

    @classmethod
    def load(cls, directory: Path) -> Self:
        meta = json.loads((directory / "map.json").read_text())
        regions = [Region.model_validate(region) for region in meta["regions"]]
        with np.load(directory / "masks.npz") as arrays:
            masks = {
                region.key: (
                    arrays[f"{region.label}/indices"],
                    arrays[f"{region.label}/weights"],
                )
                for region in regions
                if region.present
            }
            dark = arrays["dark"]
        return cls(tuple(meta["shape"]), meta["level"], regions, masks, dark)


def annotate(led_map: LedMap, image: np.ndarray) -> np.ndarray:
    """Draw each present region's outline and label on a BGR image."""
    canvas = image.copy()
    height, width = led_map.shape
    for region in led_map.present():
        indices, _ = led_map.masks[region.key]
        mask = np.zeros(height * width, dtype=np.uint8)
        mask[indices] = 255
        contours, _ = cv2.findContours(
            mask.reshape(height, width), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        colour = (0, 0, 255) if region.saturated_px else (0, 255, 255)
        cv2.drawContours(canvas, contours, -1, colour, 1)
        assert region.centroid is not None
        x, y = region.centroid
        cv2.putText(
            canvas,
            f"{region.chain[0]}{region.chip}.{region.channel}",
            (int(x) + 4, int(y) - 4),
            cv2.FONT_HERSHEY_PLAIN,
            0.8,
            colour,
            1,
        )
    return canvas
