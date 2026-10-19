# PROTOTYPE (wayfinder #37), throwaway: turn the parity positions and the FP32 reference outputs (parity.py npz files)
# into raw little-endian float32 files the Swift harness reads, with a manifest of names and shapes.
#
# usage: python -I export_assets.py <inputs.npz> <reference.npz> <outDir>
import json
import sys
from pathlib import Path

import numpy as np

HEADS = ["policy_p2_conv", "policy_pass", "value_v3_bias", "value_sv3_bias", "value_ownership_conv"]


def main():
    inp, ref, out = np.load(sys.argv[1]), np.load(sys.argv[2]), Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    arrays = {k: inp[k] for k in ("spatial_input", "global_input", "input_mask")}
    arrays.update({f"ref_{h}": ref[h] for h in HEADS})
    manifest = {"labels": [str(s) for s in inp["labels"]], "arrays": {}}
    for name, a in arrays.items():
        a = np.ascontiguousarray(a, dtype="<f4")
        a.tofile(out / f"{name}.f32")
        manifest["arrays"][name] = list(a.shape)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1))
    print(f"{out}: {len(manifest['labels'])} positions, {sorted(manifest['arrays'])}")


if __name__ == "__main__":
    main()
