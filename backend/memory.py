"""Hand freed memory back to the operating system.

Python keeps freed heap memory for reuse, so a worker that once built a large
scene stays large. Trimming after big jobs returns it on Linux and macOS.
"""

import ctypes
import ctypes.util
import gc
import sys

_trim = None


def _load():
    global _trim
    if _trim is not None:
        return _trim
    _trim = False
    try:
        if sys.platform.startswith("linux"):
            libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6")
            _trim = lambda: libc.malloc_trim(0)  # noqa: E731
        elif sys.platform == "darwin":
            libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.dylib")
            libc.malloc_zone_pressure_relief.argtypes = (ctypes.c_void_p, ctypes.c_size_t)
            _trim = lambda: libc.malloc_zone_pressure_relief(None, 0)  # noqa: E731
    except (OSError, AttributeError):
        _trim = False
    return _trim


def release():
    """Collect garbage and return free heap pages to the OS where supported."""
    gc.collect()
    trim = _load()
    if trim:
        try:
            trim()
        except OSError:
            pass
