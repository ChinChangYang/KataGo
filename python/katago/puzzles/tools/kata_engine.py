"""Thin wrapper around KataGo's analysis engine (subprocess + line-delimited JSON).

Used offline to generate the endgame-puzzle corpus. Requires a built ``katago``
binary and a neural-net model (a 9x9-capable net ships in
``cpp/tests/models/``). See ``README.md`` in this directory.
"""
import json
import subprocess
import threading

_COLS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"


def gtp(x: int, y: int, size: int = 9) -> str:
    """(x, y) with y=0 at the TOP -> GTP coordinate (bottom-origin, skips 'I')."""
    return "%s%d" % (_COLS[x], size - y)


def gtp_to_xy(coord: str, size: int = 9):
    if coord == "pass":
        return None
    return _COLS.index(coord[0]), size - int(coord[1:])


class KataGo:
    def __init__(self, katago_path: str, config_path: str, model_path: str, extra=None):
        self.n = 0
        self.p = subprocess.Popen(
            [katago_path, "analysis", "-config", config_path, "-model", model_path]
            + (extra or []),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self._err = []
        threading.Thread(target=self._pump_stderr, daemon=True).start()

    def _pump_stderr(self):
        for line in self.p.stderr:
            self._err.append(line.decode(errors="replace"))
            del self._err[:-200]

    def query(self, q: dict) -> dict:
        q.setdefault("id", str(self.n))
        self.n += 1
        self.p.stdin.write((json.dumps(q) + "\n").encode())
        self.p.stdin.flush()
        line = ""
        while line == "":
            if self.p.poll() is not None:
                raise RuntimeError("katago exited:\n" + "".join(self._err[-20:]))
            line = self.p.stdout.readline().decode().strip()
        return json.loads(line)

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()
