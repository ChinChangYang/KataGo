# PROTOTYPE (wayfinder #36), throwaway: translate the MIL program that MILBuilder writes into a
# Core AI .aimodel, op for op, so both frameworks run the identical graph and weights.
#
# usage: python -I mil_to_coreai.py <in.mlpackage> <out.aimodel> [--peaks]
#   --peaks adds one output, "peaks": max |x| of every rank-4 conv and add result and every reduce_sum, to measure FP16
#   headroom in an FP32 run (the names go to <out.aimodel>.peaks.json).
import collections
import json
import shutil
import sys
from pathlib import Path
from typing import Annotated

import numpy as np
import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load as milproto_load

import coreai  # noqa: F401  (import before coreai._compiler: circular-import quirk)
from coreai import authoring as A
from coreai.authoring import AIProgram, Module, TensorSpec, Value

I32 = np.int32
U32 = np.uint32
MIL_DTYPES = {"fp16": np.float16, "fp32": np.float32}


def load_mil(pkg):
    m = ct.models.MLModel(pkg, skip_model_load=True)
    spec = m.get_spec()
    return milproto_load(spec, spec.specificationVersion, m.weights_dir).functions["main"]


def np_dtype(var):
    s = var.dtype.__name__
    if s in ("fp16",) or "16" in str(var.dtype):
        return np.float16
    return np.float32


def peak_ops(fn_mil):
    return [op.outputs[0].name for op in fn_mil.operations
            if (op.op_type in ("conv", "add") and len(op.outputs[0].shape) == 4) or op.op_type == "reduce_sum"]


def translate(fn_mil, op_counts, peaks=None):
    shapes = {op.outputs[0].name: op.outputs[0].shape for op in fn_mil.operations}

    def body(*args):
        env = dict(zip(fn_mil.inputs.keys(), args))

        def get(var):
            return env[var.name]

        def cval(op, key, default=None):
            v = op.inputs.get(key)
            return default if v is None else v.val

        for op in fn_mil.operations:
            t = op.op_type
            out = op.outputs[0].name
            op_counts[t] += 1
            if t == "const":
                env[out] = np.asarray(op.outputs[0].val)
            elif t in ("add", "sub", "mul", "real_div"):
                f = {"add": A.broadcasting_add, "sub": A.broadcasting_sub,
                     "mul": A.broadcasting_mul, "real_div": A.broadcasting_divide}[t]
                env[out] = f(get(op.inputs["x"]), get(op.inputs["y"]))
            elif t == "exp":
                env[out] = A.exp(get(op.inputs["x"]))
            elif t == "sqrt":
                env[out] = A.sqrt(get(op.inputs["x"]))
            elif t == "cast":
                env[out] = A.cast(get(op.inputs["x"]), MIL_DTYPES[cval(op, "dtype")])
            elif t == "conv":
                x = get(op.inputs["x"])
                w = get(op.inputs["weight"])
                k_h, k_w = w.shape[2], w.shape[3]
                dil = [int(d) for d in cval(op, "dilations", [1, 1])]
                pad_type = cval(op, "pad_type", "valid")
                if pad_type == "custom":
                    t_, b_, l_, r_ = [int(p) for p in cval(op, "pad")]
                elif pad_type == "same":
                    th, tw = dil[0] * (k_h - 1), dil[1] * (k_w - 1)
                    t_, b_, l_, r_ = th // 2, th - th // 2, tw // 2, tw - tw // 2
                else:
                    t_ = b_ = l_ = r_ = 0
                if t_ or b_ or l_ or r_:
                    x = A.pad(x, np.array([0, 0, 0, 0, t_, b_, l_, r_], dtype=U32),
                              np.array(0, dtype=w.dtype))
                y = A.conv2d(x, w, np.array([int(s) for s in cval(op, "strides", [1, 1])], dtype=U32),
                             np.array(dil, dtype=U32), np.array(int(cval(op, "groups", 1)), dtype=U32))
                if op.inputs.get("bias") is not None:
                    y = A.broadcasting_add(y, get(op.inputs["bias"]).reshape(1, -1, 1, 1))
                env[out] = y
            elif t == "matmul":
                x, y = get(op.inputs["x"]), get(op.inputs["y"])
                if cval(op, "transpose_x", False):
                    x = x.T if isinstance(x, np.ndarray) else A.transpose(x, np.array([1, 0], dtype=I32))
                if cval(op, "transpose_y", False):
                    y = y.T if isinstance(y, np.ndarray) else A.transpose(y, np.array([1, 0], dtype=I32))
                env[out] = A.batch_matmul(x, np.ascontiguousarray(y) if isinstance(y, np.ndarray) else y)
            elif t == "linear":
                w = get(op.inputs["weight"])  # (N, K)
                y = A.batch_matmul(get(op.inputs["x"]), np.ascontiguousarray(w.T))
                if op.inputs.get("bias") is not None:
                    y = A.broadcasting_add(y, get(op.inputs["bias"]))
                env[out] = y
            elif t == "reshape":
                env[out] = A.reshape(get(op.inputs["x"]), np.array(cval(op, "shape"), dtype=I32))
            elif t in ("reduce_sum", "reduce_max", "reduce_mean"):
                f = {"reduce_sum": A.reduce_sum, "reduce_max": A.reduce_max, "reduce_mean": A.reduce_mean}[t]
                axes = np.array(cval(op, "axes"), dtype=I32)
                y = f(get(op.inputs["x"]), axes)
                if not cval(op, "keep_dims", False):
                    y = A.shrink_dims(y, axes)
                env[out] = y
            elif t == "squeeze":
                axes = cval(op, "axes")
                if axes is None:
                    axes = [i for i, d in enumerate(op.inputs["x"].shape) if d == 1]
                env[out] = A.shrink_dims(get(op.inputs["x"]), np.array(axes, dtype=I32))
            elif t == "concat":
                assert not cval(op, "interleave", False)
                env[out] = A.concat(np.array(int(cval(op, "axis")), dtype=I32),
                                    [get(v) for v in op.inputs["values"]])
            else:
                raise NotImplementedError(f"MIL op {t} ({out})")
        outs = [env[o.name] for o in fn_mil.outputs]
        if peaks:
            ps = [A.reshape(A.reduce_max(A.abs_(env[n]), np.arange(len(shapes[n]), dtype=I32)),
                            np.array([1], dtype=I32)) for n in peaks]
            outs.append(A.concat(np.array(0, dtype=I32), ps))
        return tuple(outs)

    # A.graph reads the parameter and return annotations, so give the function one named
    # parameter per MIL input.
    names = list(fn_mil.inputs.keys())
    ns = {"body": body}
    exec(f"def main({', '.join(names)}):\n    return body({', '.join(names)})\n", ns)
    fn = ns["main"]
    ann = {n: Annotated[Value, TensorSpec(shape=list(v.shape), dtype=np_dtype(v))] for n, v in fn_mil.inputs.items()}
    outs = [Annotated[Value, TensorSpec(shape=list(o.shape), dtype=np_dtype(o), name=o.name)] for o in fn_mil.outputs]
    if peaks:
        outs.append(Annotated[Value, TensorSpec(shape=[len(peaks)], dtype=np.float32, name="peaks")])
    ann["return"] = tuple.__class_getitem__(tuple(outs))
    fn.__annotations__ = ann
    return fn


def main():
    src, dst = sys.argv[1], Path(sys.argv[2])
    fn_mil = load_mil(src)
    peaks = peak_ops(fn_mil) if "--peaks" in sys.argv else None
    op_counts = collections.Counter()
    module = Module.create()
    with module:
        A.graph(translate(fn_mil, op_counts, peaks), provided_name="main")
    module.verify()
    text = str(module)
    # The ANE turns log(exp(x) + c) into 0 for x >= 10.3984 (research note section 3.3), so
    # the program must contain no log at all; Mish arrives in MILBuilder's branch-free form.
    assert "coreai.log" not in text and "coreai.tanh" not in text, "log/tanh emitted"
    shutil.rmtree(dst, ignore_errors=True)
    AIProgram(module).save_asset(dst)
    if peaks:
        Path(f"{dst}.peaks.json").write_text(json.dumps(peaks))
    print(f"wrote {dst}: MIL ops {dict(op_counts)}; coreai ops "
          f"{dict(collections.Counter(w for w in text.split() if w.startswith('coreai.')))}")


if __name__ == "__main__":
    main()
