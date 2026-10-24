from neon_rig.camera import Settings, lock_plan, parse_controls

# v4l2-ctl --list-ctrls from a UVC webcam on a 6.x kernel.
NEW_NAMES = """
User Controls

                     brightness 0x00980900 (int)    : min=-64 max=64 step=1 default=0 value=0
        white_balance_automatic 0x0098090c (bool)   : default=1 value=1
                           gain 0x00980913 (int)    : min=0 max=100 step=1 default=0 value=12
           power_line_frequency 0x00980918 (menu)   : min=0 max=2 default=1 value=2 (60 Hz)
      white_balance_temperature 0x0098091a (int)    : min=2800 max=6500 step=1 default=4600 value=4600 flags=inactive

Camera Controls

                  auto_exposure 0x009a0901 (menu)   : min=0 max=3 default=3 value=3 (Aperture Priority Mode)
         exposure_time_absolute 0x009a0902 (int)    : min=3 max=150 step=1 default=157 value=157 flags=inactive
     exposure_dynamic_framerate 0x009a0903 (bool)   : default=0 value=1
"""

# The same camera on an older kernel, with focus controls.
OLD_NAMES = """
 white_balance_temperature_auto 0x0098090c (bool)   : default=1 value=1
                  exposure_auto 0x009a0901 (menu)   : min=0 max=3 default=3 value=3 (Aperture Priority Mode)
              exposure_absolute 0x009a0902 (int)    : min=3 max=2047 step=1 default=250 value=250 flags=inactive
         exposure_auto_priority 0x009a0903 (bool)   : default=0 value=1
                     focus_auto 0x009a090c (bool)   : default=1 value=1
                 focus_absolute 0x009a090a (int)    : min=0 max=250 step=5 default=0 value=0 flags=inactive
"""


def test_automatic_modes_go_off_before_their_manual_values() -> None:
    plan = lock_plan(parse_controls(NEW_NAMES), Settings(exposure_ms=20))

    assert plan == [
        ("auto_exposure", 1),
        ("exposure_dynamic_framerate", 0),
        # 20 ms is 200 units of 100 us, but this camera stops at 150.
        ("exposure_time_absolute", 150),
        ("gain", 0),
        ("white_balance_automatic", 0),
        ("white_balance_temperature", 4600),
        ("power_line_frequency", 1),
    ]


def test_older_control_names_and_focus() -> None:
    plan = lock_plan(parse_controls(OLD_NAMES), Settings(exposure_ms=20, focus=40))

    assert plan == [
        ("exposure_auto", 1),
        ("exposure_auto_priority", 0),
        ("exposure_absolute", 200),
        ("white_balance_temperature_auto", 0),
        ("focus_auto", 0),
        ("focus_absolute", 40),
    ]
