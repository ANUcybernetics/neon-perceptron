import subprocess
from typing import Any

import pytest

from neon_rig.pi import Atom, PiError, Relatch, SshPi, Wobble, elixir


class FakeSsh:
    def __init__(
        self, stdout: str = 'LAB {"ok":"ok"}\n:ok', returncode: int = 0
    ) -> None:
        self.stdout = stdout
        self.returncode = returncode
        self.commands: list[str] = []

    def __call__(
        self, argv: list[str], **_options: Any
    ) -> subprocess.CompletedProcess[str]:
        assert argv[0] == "ssh" and argv[-2] == "nerves.local"
        self.commands.append(argv[-1])
        return subprocess.CompletedProcess(argv, self.returncode, self.stdout, "boom")


def test_calls_become_lab_expressions_wrapped_in_reply() -> None:
    ssh = FakeSsh()
    pi = SshPi("nerves.local", runner=ssh)

    pi.light_one("main", 6, 18, 2048)
    pi.start(Relatch(30, chains=("main",)))
    pi.start(Wobble("main", 6, 18, 0.01))
    pi.configure("main", blank_gpio="GPIO17", blank_pulse=True)
    pi.fill(4095)

    assert ssh.commands == [
        "NeonPerceptron.Lab.reply(NeonPerceptron.Lab.light_one(:main, 6, 18, 2048))",
        (
            "NeonPerceptron.Lab.reply(NeonPerceptron.Lab.start("
            "%{rate_hz: 30.0, kind: :relatch, latch: :xlat, chains: [:main]}))"
        ),
        (
            "NeonPerceptron.Lab.reply(NeonPerceptron.Lab.start(%{kind: :wobble, chain: :main, "
            "chip: 6, channel: 18, depth: 0.01, freq_hz: 5.0, rate_hz: 30.0, latch: :xlat}))"
        ),
        (
            "NeonPerceptron.Lab.reply(NeonPerceptron.Lab.configure(:main, "
            '%{blank_gpio: "GPIO17", blank_pulse: true}))'
        ),
        "NeonPerceptron.Lab.reply(NeonPerceptron.Lab.fill(4095))",
    ]


def test_results_come_from_the_lab_line_among_other_output() -> None:
    for stdout in [
        'LAB {"ok":{"ticks":12,"kind":"relatch"}}',
        ':okLAB {"ok":{"ticks":12,"kind":"relatch"}}\n',
        'Interactive Elixir\r\niex(1)> LAB {"ok":{"ticks":12,"kind":"relatch"}}\r\n',
    ]:
        pi = SshPi("nerves.local", runner=FakeSsh(stdout))
        assert pi.stop() == {"ticks": 12, "kind": "relatch"}


def test_lab_errors_and_ssh_failures_raise() -> None:
    with pytest.raises(PiError, match="no_blank_gpio"):
        SshPi("nerves.local", runner=FakeSsh('LAB {"error":":no_blank_gpio"}')).stop()
    with pytest.raises(PiError, match="boom"):
        SshPi("nerves.local", runner=FakeSsh("", returncode=255)).stop()
    with pytest.raises(PiError, match="boom"):
        SshPi("nerves.local", runner=FakeSsh(":ok", returncode=1)).stop()


def test_a_complete_reply_wins_over_a_lost_exit_status() -> None:
    ssh = FakeSsh('LAB {"ok":{"ticks":3}}', returncode=255)

    assert SshPi("nerves.local", runner=ssh).stop() == {"ticks": 3}


def test_elixir_literals() -> None:
    assert elixir(1e-5) == "0.00001"
    assert elixir(2.0) == "2.0"
    assert elixir([Atom("a"), None, False]) == "[:a, nil, false]"
    with pytest.raises(ValueError):
        elixir('GPIO17"); System.halt(')
    with pytest.raises(ValueError):
        Atom("Main")
