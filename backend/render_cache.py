"""Bounded LRU cache for completed renders, shared by preview, export and upload."""

from collections import OrderedDict


class RenderCache:
    def __init__(self, max_bytes=64 * 1024 * 1024):
        self.max_bytes = max_bytes
        self.bytes = 0
        self.items = OrderedDict()

    def get(self, key):
        value = self.items.pop(key, None)
        if value is not None:
            self.items[key] = value
        return value

    def put(self, key, value):
        if value.nbytes > self.max_bytes:
            return
        previous = self.items.pop(key, None)
        if previous is not None:
            self.bytes -= previous.nbytes
        while self.items and self.bytes + value.nbytes > self.max_bytes:
            _, old = self.items.popitem(last=False)
            self.bytes -= old.nbytes
        self.items[key] = value
        self.bytes += value.nbytes
