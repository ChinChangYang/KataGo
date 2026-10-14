#!/usr/bin/env python3
"""Generates EngineParameterCatalog+Generated.swift: every engine parameter
the app's GTP engine reads, with its type, range, live/launch timing, the
description and value from KataGo's example cfgs, and the app's own value from
the bundled default_gtp.cfg.

Sources (paths relative to the repo root):
  - cpp/program/setup.cpp, cpp/command/gtp.cpp, cpp/neuralnet/mlxbackend.cpp:
    every `cfg.getXxx("key", min, max)` call names a key the engine reads, its
    type and its range. Keys built from a runtime prefix (backend/device keys)
    are not literals and so never appear.
  - Live = read by Setup::loadParams or by the GTP loadParams lambda, or one of
    the four keys kata-set-param handles itself; minus the keys kata-set-param
    refuses. Everything else is read once, at launch.
  - cpp/configs/gtp_example.cfg (then the other example cfgs): the comment
    paragraph above a `key = value` line describes it; the section banner it
    sits under names its section.
  - ios/KataGo iOS/Resources/default_gtp.cfg: the app's shipped values.

Run from anywhere:  python3 "ios/KataGo iOS/scripts/generate_engine_parameter_catalog.py"
"""
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
CPP = os.path.join(REPO, "cpp")
APP_CFG = os.path.join(REPO, "ios", "KataGo iOS", "Resources", "default_gtp.cfg")
OUT = os.path.join(REPO, "ios", "KataGo iOS", "KataGoUICore", "Sources",
                   "EngineParametersKit", "EngineParameterCatalog+Generated.swift")

SOURCES = ["program/setup.cpp", "command/gtp.cpp", "neuralnet/mlxbackend.cpp"]
EXAMPLE_CFGS = ["gtp_example.cfg", "analysis_example.cfg",
                "gtp_human5k_example.cfg", "gtp_human9d_search_example.cfg"]

# kata-set-param handles these itself (gtp.cpp, after loadParams).
LIVE_EXTRA = {"allowResignation", "ponderingEnabled", "delayMoveScale", "delayMoveMax"}
# kata-set-param refuses these: two by name, three via
# SearchParams::failIfParamsDifferOnUnchangeableParameter.
LIVE_REFUSED = {"dynamicPlayoutDoublingAdvantageCapPerOppLead", "avoidRepeatedPatternUtility",
                "nodeTableShardsPowerOfTwo", "useEvalCache", "evalCacheMinVisits"}

GET_RE = re.compile(
    r'(?:cfg|config)\.get(Int64|UInt64|Int|Double|Float|Bool|String|Enabled)\(\s*"([A-Za-z][A-Za-z0-9_]*)"'
    r'\s*(?:\+\s*[A-Za-z_]+\s*)?(?:,\s*([^,()]+?)\s*,\s*([^,()]+?)\s*\))?')
KEY_LINE_RE = re.compile(r'^#?\s*([A-Za-z][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$')
KIND = {"Int64": "integer", "UInt64": "integer", "Int": "integer", "Double": "real", "Float": "real",
        "Bool": "bool", "String": "text", "Enabled": "enabled"}


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def body_lines(lines, start_pattern):
    """1-based [first, last] line range of the function whose signature starts
    at the first line matching start_pattern and whose body opens with `) {`."""
    for i, line in enumerate(lines):
        if re.match(start_pattern, line):
            j = i
            while not lines[j].rstrip().endswith("{"):
                j += 1
            depth = 0
            for k in range(j, len(lines)):
                depth += lines[k].count("{") - lines[k].count("}")
                if depth == 0:
                    return (i + 1, k + 1)
    sys.exit("generator: function not found: " + start_pattern)


def scan_sources():
    params = {}
    live = set(LIVE_EXTRA)
    for rel in SOURCES:
        with open(os.path.join(CPP, rel)) as f:
            lines = f.read().split("\n")
        live_ranges = []
        if rel == "program/setup.cpp":
            # Of the loadParams overloads, the one with the body declares loadSingleConfigOnly
            # and opens `) {` on its own line.
            for i, line in enumerate(lines):
                if line.startswith("vector<SearchParams> Setup::loadParams(") and \
                        any(l.startswith(") {") for l in lines[i:i + 7]) and \
                        any("setup_for_t setupFor" in l for l in lines[i:i + 7]) and \
                        not any("return loadParams" in l for l in lines[i:i + 9]):
                    a, b = body_lines(lines[i:], r'^vector<SearchParams> Setup::loadParams\(')
                    live_ranges.append((a + i, b + i))
            if len(live_ranges) != 1:
                sys.exit("generator: expected one Setup::loadParams body, found %d" % len(live_ranges))
        if rel == "command/gtp.cpp":
            first = next(i for i, l in enumerate(lines) if "auto loadParams = [" in l)
            last = next(i for i in range(first, len(lines)) if lines[i].strip() == "};")
            live_ranges.append((first + 1, last + 1))
        for number_, line in enumerate(lines, start=1):
            if line.lstrip().startswith("//"):
                continue
            for m in GET_RE.finditer(line):
                kind, key, lo, hi = m.group(1), m.group(2), m.group(3), m.group(4)
                entry = params.setdefault(key, {"kind": KIND[kind], "min": None, "max": None})
                if number(lo) is not None and number(hi) is not None:
                    entry["min"], entry["max"] = number(lo), number(hi)
                if any(a <= number_ <= b for a, b in live_ranges):
                    live.add(key)
    for key in params:
        params[key]["live"] = key in live and key not in LIVE_REFUSED
    return params


def scan_example(path, docs):
    section = ""
    paragraph = []
    with open(path) as f:
        lines = [l.rstrip("\n") for l in f]
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        # Section banner: a rule line, a title line, a rule line.
        if re.match(r'^#\s*[-=]{10,}\s*$', line) and i + 2 < len(lines) and \
                re.match(r'^#\s*[-=]{10,}\s*$', lines[i + 2].strip()):
            section = lines[i + 1].strip().lstrip("#").strip()
            paragraph = []
            i += 3
            continue
        if not line:
            paragraph = []
        else:
            m = KEY_LINE_RE.match(line)
            if m:
                key, value = m.group(1), m.group(2).split("#")[0].strip()
                if key not in docs:
                    docs[key] = {"section": section, "summary": " ".join(paragraph), "value": value}
            elif line.startswith("#"):
                text = line.lstrip("#").strip()
                if text:
                    paragraph.append(text)
        i += 1


def scan_app_cfg():
    values = {}
    with open(APP_CFG) as f:
        for line in f:
            line = line.split("#")[0].strip()
            m = KEY_LINE_RE.match(line)
            if m:
                values[m.group(1)] = m.group(2)
    return values


def swift_string(text):
    if text is None:
        return "nil"
    if any(ord(c) > 127 for c in text):
        sys.exit("generator: non-ASCII text: " + text)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swift_number(value, integer):
    if integer:
        return str(int(value))
    text = repr(float(value))
    return text if ("e" in text or "." in text) else text + ".0"


def swift_kind(entry):
    kind = entry["kind"]
    has_range = entry["min"] is not None
    if kind == "integer":
        rng = "%s...%s" % (swift_number(entry["min"], True), swift_number(entry["max"], True)) if has_range else "nil"
        return ".integer(%s)" % rng
    if kind == "real":
        rng = "%s...%s" % (swift_number(entry["min"], False), swift_number(entry["max"], False)) if has_range else "nil"
        return ".real(%s)" % rng
    return "." + kind


def main():
    params = scan_sources()
    docs = {}
    for name in EXAMPLE_CFGS:
        scan_example(os.path.join(CPP, "configs", name), docs)
    app = scan_app_cfg()

    out = ["// Generated by scripts/generate_engine_parameter_catalog.py. Do not edit.",
           "// Regenerate after changing the engine's config reads, the example cfgs or default_gtp.cfg.",
           "",
           "extension EngineParameterCatalog {",
           "    static let generatedParameters: [EngineParameter] = ["]
    for key in sorted(params, key=str.lower):
        entry = params[key]
        doc = docs.get(key, {})
        out.append("        EngineParameter(key: %s, kind: %s, timing: %s, section: %s, summary: %s, exampleValue: %s),"
                   % (swift_string(key), swift_kind(entry), ".live" if entry["live"] else ".launch",
                      swift_string(doc.get("section", "")), swift_string(doc.get("summary", "")),
                      swift_string(doc.get("value"))))
    out += ["    ]", "", "    /// The values the app ships in default_gtp.cfg.",
            "    static let generatedAppValues: [String: String] = ["]
    for key in sorted(app, key=str.lower):
        out.append("        %s: %s," % (swift_string(key), swift_string(app[key])))
    out += ["    ]", "}", ""]
    with open(OUT, "w") as f:
        f.write("\n".join(out))
    print("generator: %d parameters, %d app values -> %s" % (len(params), len(app), os.path.relpath(OUT, REPO)))


if __name__ == "__main__":
    main()
