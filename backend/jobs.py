"""Serialize backend jobs for the threaded HTTP server."""

import queue
import threading
import traceback


class Superseded(Exception):
    """A newer preview from the same client replaced this one before it ran."""


class Job:
    def __init__(self, function, client=None):
        self.function = function
        self.client = client
        self.done = threading.Event()
        self.result = None
        self.error = None
        self.started = False
        self.cancelled = False


class JobQueue:
    def __init__(self):
        self.queue = queue.Queue()
        self.latest = {}
        self.lock = threading.Lock()
        self.busy = False

    def submit(self, function, client=None, timeout=None):
        """Queue work and block the calling (HTTP) thread until it finishes.

        With a client key, only that client's newest job runs; older queued ones raise Superseded.
        """
        job = Job(function, client)
        if client is not None:
            with self.lock:
                self.latest[client] = job
        self.queue.put(job)
        if not job.done.wait(timeout):
            with self.lock:
                if not job.started:
                    job.cancelled = True
                    if client is not None and self.latest.get(client) is job:
                        del self.latest[client]
                    raise TimeoutError("Render timed out before it started")
            # Running work has worker-level timeouts. Wait for its outcome so an
            # export never writes files after its caller has reported failure.
            job.done.wait()
        if job.error is not None:
            raise job.error
        return job.result

    def run_pending(self, timeout=0.25):
        """Drain jobs on the main thread. Returns after timeout when idle."""
        try:
            job = self.queue.get(timeout=timeout)
        except queue.Empty:
            return
        with self.lock:
            if job.cancelled:
                job.done.set()
                return
            if job.client is not None and self.latest.get(job.client) is not job:
                job.error = Superseded()
                job.done.set()
                return
            job.started = True
        self.busy = True
        try:
            job.result = job.function()
        except Exception as error:  # noqa: BLE001 - errors are reported to the HTTP client
            traceback.print_exc()
            job.error = error
        finally:
            self.busy = False
            if job.client is not None:
                with self.lock:
                    if self.latest.get(job.client) is job:
                        del self.latest[job.client]
            job.done.set()
