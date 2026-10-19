# PROTOTYPE (wayfinder #37), throwaway: the FP16 Mish sweep models (research note section 3.6), for both frameworks.
#
# usage: python -I build_mish.py <outDir> <translator.py>
#
#   mish_ml.mlpackage        MILBuilder::addMishOps op for op: e = exp(x), x / (1 + 2 / (e * (e + 2))), FP16 compute,
#                            FP32 I/O with casts, as in the network. No coremltools passes run, so nothing is rewritten.
#   mish_ai.aimodel          the same program through mil_to_coreai.py, the translator the network goes through.
#   mishtorch_ml.mlpackage   positive control: PyTorch's decomposition x * tanh(where(x > 20, x, log(exp(x) + 1))),
#   mishtorch_ai.aimodel     which the Neural Engine turns into 0 for x in [10.3984, 20]. A sweep that does not catch it
#                            proves nothing.
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Annotated

import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil import types

import coreai  # noqa: F401  (import before coreai._compiler: circular-import quirk)
from coreai import authoring as A
from coreai.authoring import AIProgram, Module, TensorSpec, Value

# 1M elements: the sweep tiled 25 times. Core ML keeps an elementwise graph of 40,960 elements on the CPU under every
# compute-unit setting (MLComputePlan); at this size it places it on the unit asked for, as Core AI does.
SHAPE = (1, 256, 64, 64)
H = np.float16


def save_ml(prog, path):
    m = ct.convert(prog, convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                   minimum_deployment_target=ct.target.iOS17, pass_pipeline=ct.PassPipeline.EMPTY)
    shutil.rmtree(path, ignore_errors=True)
    m.save(str(path))


@mb.program(input_specs=[mb.TensorSpec(shape=SHAPE, dtype=types.fp32)], opset_version=ct.target.iOS17)
def mish_prog(x):
    h = mb.cast(x=x, dtype="fp16")
    e = mb.exp(x=h)
    ep2 = mb.add(x=e, y=H(2))
    emep2 = mb.mul(x=e, y=ep2)
    tdemep2 = mb.real_div(x=H(2), y=emep2)
    optdemep2 = mb.add(x=H(1), y=tdemep2)
    return mb.cast(x=mb.real_div(x=h, y=optdemep2), dtype="fp32", name="y")


@mb.program(input_specs=[mb.TensorSpec(shape=SHAPE, dtype=types.fp32)], opset_version=ct.target.iOS17)
def mishtorch_prog(x):
    h = mb.cast(x=x, dtype="fp16")
    sp = mb.select(cond=mb.greater(x=h, y=H(20)), a=h, b=mb.log(x=mb.add(x=mb.exp(x=h), y=H(1))))
    return mb.cast(x=mb.mul(x=h, y=mb.tanh(x=sp)), dtype="fp32", name="y")


def mishtorch_ai(path):
    module = Module.create()
    with module:
        def main(x: Annotated[Value, TensorSpec(shape=list(SHAPE), dtype=np.float32)]) -> Annotated[
                Value, TensorSpec(shape=list(SHAPE), dtype=np.float32, name="y")]:
            h = A.cast(x, H)
            sp = A.where(A.broadcasting_greater(h, np.array(20, dtype=H)), h,
                         A.log(A.broadcasting_add(A.exp(h), np.array(1, dtype=H))))
            return A.cast(A.mul(h, A.tanh(sp)), np.float32)
        A.graph(main, provided_name="main")
    module.verify()
    shutil.rmtree(path, ignore_errors=True)
    AIProgram(module).save_asset(path)


def main():
    out, translator = Path(sys.argv[1]), sys.argv[2]
    out.mkdir(parents=True, exist_ok=True)
    save_ml(mish_prog, out / "mish_ml.mlpackage")
    subprocess.run([sys.executable, "-I", translator, str(out / "mish_ml.mlpackage"), str(out / "mish_ai.aimodel")],
                   check=True)
    save_ml(mishtorch_prog, out / "mishtorch_ml.mlpackage")
    mishtorch_ai(out / "mishtorch_ai.aimodel")
    print(f"wrote the Mish sweep models to {out}")


if __name__ == "__main__":
    main()
