"""Drive the LED Pi's `NeonPerceptron.Lab` over SSH.

NervesSSH evaluates the command of `ssh host '<elixir>'` as Elixir and sends
back `inspect/1` of the result. Every call here wraps its expression in
`NeonPerceptron.Lab.reply/1`, whose result inspects as one `LAB {"ok": ...}` or
`LAB {"error": ...}` line. An SSH control master keeps one connection open
between calls.
"""

import json
import re
import subprocess
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any, Literal, Protocol

SSH_OPTIONS = (
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=5",
    "-o",
    "StrictHostKeyChecking=accept-new",
    "-o",
    "ControlMaster=auto",
    "-o",
    "ControlPath=~/.ssh/neon-rig-%C",
    "-o",
    "ControlPersist=300",
)

Latch = Literal["xlat", "blank_pulse"]


class PiError(RuntimeError):
    """The Pi was unreachable, or Lab returned an error."""


@dataclass(frozen=True)
class Atom:
    """An Elixir atom, e.g. a chain id."""

    name: str

    def __post_init__(self) -> None:
        if not re.fullmatch(r"[a-z_][a-z0-9_]*", self.name):
            raise ValueError(f"not a plain atom: {self.name!r}")


@dataclass(frozen=True)
class Relatch:
    """Shift and latch the same frames `rate_hz` times a second, each tick up
    to `jitter_ms` either side of its slot."""

    rate_hz: float
    latch: Latch = "xlat"
    chains: tuple[str, ...] | None = None
    jitter_ms: float = 0.0


@dataclass(frozen=True)
class Reshift:
    """Shift the same frames `rate_hz` times a second without latching, each
    tick up to `jitter_ms` either side of its slot."""

    rate_hz: float
    chains: tuple[str, ...] | None = None
    jitter_ms: float = 0.0


@dataclass(frozen=True)
class Wobble:
    """Vary one channel's level by a fraction `±depth` at `freq_hz`."""

    chain: str
    chip: int
    channel: int
    depth: float
    freq_hz: float = 5.0
    rate_hz: float = 30.0
    latch: Latch = "xlat"


type Condition = Relatch | Reshift | Wobble


@dataclass(frozen=True)
class ChainInfo:
    id: str
    chips: int
    mode: str
    held: bool
    switches: dict[str, Any]


class Pi(Protocol):
    """What the experiments need from the LED Pi (see `NeonPerceptron.Lab`)."""

    def chains(self) -> list[ChainInfo]: ...
    def fill(self, level: int, chain: str | None = None) -> None: ...
    def light_one(self, chain: str, chip: int, channel: int, level: int) -> None: ...
    def start(self, condition: Condition) -> None: ...
    def stop(self) -> dict[str, Any]: ...
    def probe_gpio(self, label: str, value: int) -> None: ...
    def release_gpio(self, label: str) -> None: ...
    def configure(self, chain: str, **switches: Any) -> None: ...
    def readback(self, chain: str, frames: int) -> dict[str, Any]: ...
    def release(self) -> None: ...


def elixir(value: Any) -> str:
    """Render a Python value as an Elixir literal."""
    match value:
        case bool():
            return "true" if value else "false"
        case None:
            return "nil"
        case Atom(name):
            return f":{name}"
        case int():
            return str(value)
        case float():
            text = f"{value:.9f}".rstrip("0")
            return text + "0" if text.endswith(".") else text
        case str() if re.fullmatch(r"[A-Za-z0-9_.:-]*", value):
            return f'"{value}"'
        case list() | tuple():
            return "[" + ", ".join(elixir(item) for item in value) + "]"
        case dict():
            pairs = (f"{Atom(key).name}: {elixir(item)}" for key, item in value.items())
            return "%{" + ", ".join(pairs) + "}"
        case _:
            raise ValueError(f"no Elixir literal for {value!r}")


def condition_term(condition: Condition) -> dict[str, Any]:
    """The `Lab.start/1` map for a condition."""
    if isinstance(condition, Wobble):
        return {
            "kind": Atom("wobble"),
            "chain": Atom(condition.chain),
            "chip": condition.chip,
            "channel": condition.channel,
            "depth": float(condition.depth),
            "freq_hz": float(condition.freq_hz),
            "rate_hz": float(condition.rate_hz),
            "latch": Atom(condition.latch),
        }
    term: dict[str, Any] = {"rate_hz": float(condition.rate_hz)}
    if isinstance(condition, Relatch):
        term |= {"kind": Atom("relatch"), "latch": Atom(condition.latch)}
    else:
        term["kind"] = Atom("reshift")
    if condition.chains is not None:
        term["chains"] = [Atom(chain) for chain in condition.chains]
    if condition.jitter_ms:
        term["jitter_ms"] = float(condition.jitter_ms)
    return term


_REPLY = re.compile(r"LAB (\{.*\})")


def reply_envelope(stdout: str) -> dict[str, Any] | None:
    """The envelope from the `LAB` line of a `Lab.reply/1` call, if any. The
    line can come after an IEx prompt or other output, so it's found
    anywhere."""
    match = _REPLY.search(stdout)
    return json.loads(match.group(1)) if match else None


type Runner = Callable[..., subprocess.CompletedProcess[str]]


class SshPi:
    """`Pi` over SSH to a Nerves device running the neon-perceptron firmware."""

    def __init__(
        self, host: str, runner: Runner = subprocess.run, timeout_s: float = 30.0
    ) -> None:
        self.host = host
        self.runner = runner
        self.timeout_s = timeout_s

    def call(self, function: str, *args: Any) -> Any:
        expression = f"NeonPerceptron.Lab.{function}({', '.join(map(elixir, args))})"
        argv: Sequence[str] = [
            "ssh",
            *SSH_OPTIONS,
            self.host,
            f"NeonPerceptron.Lab.reply({expression})",
        ]
        result = self.runner(
            argv, capture_output=True, text=True, timeout=self.timeout_s
        )
        envelope = reply_envelope(result.stdout)
        # A multiplexed session now and then ends without passing on the exit
        # status, so ssh exits 255 after a complete reply. The LAB line only
        # exists once the call has run, so it outranks the exit code.
        if envelope is None:
            raise PiError(
                f"ssh {self.host} failed ({result.returncode}): "
                f"{result.stderr.strip() or result.stdout.strip() or 'no reply'}"
            )
        if "error" in envelope:
            raise PiError(f"Lab returned an error: {envelope['error']}")
        return envelope["ok"]

    def chains(self) -> list[ChainInfo]:
        return [
            ChainInfo(
                id=info["id"],
                chips=info["chips"],
                mode=info["mode"],
                held=info["held"],
                switches=info["switches"],
            )
            for info in self.call("chains")
        ]

    def fill(self, level: int, chain: str | None = None) -> None:
        if chain is None:
            self.call("fill", level)
        else:
            self.call("fill", Atom(chain), level)

    def light_one(self, chain: str, chip: int, channel: int, level: int) -> None:
        self.call("light_one", Atom(chain), chip, channel, level)

    def start(self, condition: Condition) -> None:
        self.call("start", condition_term(condition))

    def stop(self) -> dict[str, Any]:
        return self.call("stop")

    def probe_gpio(self, label: str, value: int) -> None:
        self.call("probe_gpio", label, value)

    def release_gpio(self, label: str) -> None:
        self.call("release_gpio", label)

    def configure(self, chain: str, **switches: Any) -> None:
        self.call("configure", Atom(chain), switches)

    def readback(self, chain: str, frames: int) -> dict[str, Any]:
        return self.call("readback", Atom(chain), frames)

    def release(self) -> None:
        self.call("release")
