"""Windows scheduling hints for the GUI (no-ops elsewhere).

On hybrid CPUs (the bench PC is an i7-12700: 8 P-cores + 4 E-cores) Windows may run a process at
"EcoQoS" and move its threads to E-cores when its window is not in the foreground (for example while
a screenshot tool has focus). Measured: measure.analyze() on 262,144 points takes 8.6 ms on a P-core
and 14-15 ms on an E-core; in the GUI the worker's FFT/metrics read 27 ms.
"""
from __future__ import annotations

import ctypes
import sys

_POWER_THROTTLING_EXECUTION_SPEED = 0x1
_PROCESS_POWER_THROTTLING = 4          # PROCESS_INFORMATION_CLASS ProcessPowerThrottling
_THREAD_POWER_THROTTLING = 3           # THREAD_INFORMATION_CLASS ThreadPowerThrottling
_THREAD_PRIORITY_ABOVE_NORMAL = 1


class _ThrottlingState(ctypes.Structure):
    _fields_ = [("Version", ctypes.c_ulong), ("ControlMask", ctypes.c_ulong), ("StateMask", ctypes.c_ulong)]


def _high_qos_state() -> _ThrottlingState:
    # ControlMask = EXECUTION_SPEED, StateMask = 0: "never throttle execution speed" (always high QoS).
    return _ThrottlingState(1, _POWER_THROTTLING_EXECUTION_SPEED, 0)


def process_high_qos() -> bool:
    """Opt the whole process out of EcoQoS. Returns True when Windows accepted it."""
    if sys.platform != "win32":
        return False
    try:
        k32 = ctypes.windll.kernel32
        k32.GetCurrentProcess.restype = ctypes.c_void_p
        k32.SetProcessInformation.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_ulong]
        state = _high_qos_state()
        return bool(k32.SetProcessInformation(k32.GetCurrentProcess(), _PROCESS_POWER_THROTTLING,
                                              ctypes.byref(state), ctypes.sizeof(state)))
    except (AttributeError, OSError):
        return False


def thread_high_qos(above_normal: bool = True) -> bool:
    """Opt the calling thread out of EcoQoS and optionally raise its priority one step."""
    if sys.platform != "win32":
        return False
    try:
        k32 = ctypes.windll.kernel32
        k32.GetCurrentThread.restype = ctypes.c_void_p
        k32.SetThreadInformation.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_ulong]
        k32.SetThreadPriority.argtypes = [ctypes.c_void_p, ctypes.c_int]
        thread = k32.GetCurrentThread()
        state = _high_qos_state()
        ok = bool(k32.SetThreadInformation(thread, _THREAD_POWER_THROTTLING, ctypes.byref(state),
                                           ctypes.sizeof(state)))
        if above_normal:
            ok = bool(k32.SetThreadPriority(thread, _THREAD_PRIORITY_ABOVE_NORMAL)) and ok
        return ok
    except (AttributeError, OSError):
        return False
