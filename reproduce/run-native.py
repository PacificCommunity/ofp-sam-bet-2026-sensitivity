#!/usr/bin/env python3
"""Regenerate and check saved native model outputs in a new directory."""
import argparse
import concurrent.futures
import contextlib
import csv
import io
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import sys
import restore
from native_directory import NativeDirectory, original_files

HERE = Path(__file__).resolve().parent
CONTROLS = b"1 1 1\n1 246 1\n"
DIMENSIONS = ("Number of time periods", "Year 1", "Number of regions",
              "Number of species", "Number of age classes", "Number of recruitments per year")
BIOMASS = ("Adult biomass", "Adult biomass in absence of fishing")
MSY = ("Adult biomass at MSY", "F multiplier at MSY")
REP_FIELDS = set(DIMENSIONS + BIOMASS + MSY)


def read_bytes(path):
    with restore.frozen_bytes(path) as data:
        return data


def par_number(data, heading):
    lines = data.decode().splitlines()
    matches = [i for i, line in enumerate(lines) if line.strip() == heading]
    if len(matches) != 1 or matches[0] + 1 >= len(lines):
        raise ValueError("Missing or duplicate PAR value: " + heading)
    tokens = lines[matches[0] + 1].split()
    if len(tokens) != 1:
        raise ValueError("Malformed PAR value: " + heading)
    value = float(tokens[0])
    if not math.isfinite(value):
        raise ValueError("Nonfinite PAR value: " + heading)
    return value


def par_count(data):
    value = par_number(data, "# The number of parameters")
    if value <= 0 or value != int(value):
        raise ValueError("Invalid active parameter count")
    return int(value)


def rep_sections(data):
    result, label = {}, None
    for line in data.decode().splitlines():
        if line.lstrip().startswith("#"):
            label = line.lstrip()[1:].strip()
            if label in REP_FIELDS:
                if label in result:
                    raise ValueError("Duplicate REP section: " + label)
                result[label] = []
        elif line.strip() and label in REP_FIELDS:
            result[label].append(line.split())
    return result


def numbers(sections, name, shape):
    rows = sections.get(name, [])
    if len(rows) != shape[0] or any(len(row) != shape[1] for row in rows):
        raise ValueError(f"Invalid REP shape: {name}; expected {shape}")
    values = [float(token) for row in rows for token in row]
    if any(not math.isfinite(x) or x <= 0 for x in values):
        raise ValueError("Invalid REP values: " + name)
    return values


def dimensions(sections):
    result = {}
    for name in DIMENSIONS:
        value = numbers(sections, name, (1, 1))[0]
        if value != int(value):
            raise ValueError("Noninteger REP dimension: " + name)
        result[name] = int(value)
    return result


def compare_rep(actual, original):
    observed, reference = rep_sections(actual), rep_sections(original)
    expected = dimensions(reference)
    if dimensions(observed) != expected:
        raise ValueError("Native REP dimensions differ from the saved report")
    shape = (expected["Number of time periods"], expected["Number of regions"])
    maximum = 0.0
    for name in BIOMASS + MSY:
        selected_shape = shape if name in BIOMASS else (1, 1)
        a, b = numbers(observed, name, selected_shape), numbers(reference, name, selected_shape)
        for x, y in zip(a, b):
            maximum = max(maximum, abs(x - y))
            if abs(x - y) > 1e-10 * max(1, abs(y)):
                raise ValueError("Native central REP differs: " + name)
    return {"reference_dimensions": expected, "central_rep_max_abs_diff": maximum}


def reference_rep(output, rule):
    record = rule["reference_rep"]
    path = HERE / restore.safe_path(record["path"])
    return restore.checked(read_bytes(path), record)


def compare_annual(actual, model, rule):
    # Validate the inferred aggregation directly against the preserved annual CSV.
    if rule.get("annual_policy") != "quarterly_biomass":
        raise ValueError("Annual comparison policy is missing")
    sections = rep_sections(actual)
    dims = dimensions(sections)
    if dims != rule["dimensions"]:
        raise ValueError("Native REP dimensions differ from the published annual series")
    quarterly = dims["Number of recruitments per year"]
    periods, regions = dims["Number of time periods"], dims["Number of regions"]
    if periods % quarterly:
        raise ValueError("Native periods do not span complete years")
    annual = []
    series = [numbers(sections, name, (periods, regions)) for name in BIOMASS]
    for index in range(periods // quarterly):
        values = [sum(values[index * quarterly * regions:(index + 1) * quarterly * regions])
                  / quarterly / 1000 for values in series]
        annual.append((dims["Year 1"] + index, values[0], values[1], values[0] / values[1]))
    data = restore.git_bytes(rule["series"])
    restore.checked(data, rule["series"])
    rows = [row for row in csv.DictReader(io.StringIO(data.decode())) if row["key"] == model]
    if len(rows) != len(annual):
        raise ValueError("Published annual series is incomplete")
    maximum = 0.0
    for row, (year, sb, sb0, depletion) in zip(rows, annual):
        if int(row["year"]) != year:
            raise ValueError("Published annual years differ")
        for name, observed in (("spawning_potential", sb), ("spawning_potential_nofish", sb0),
                               ("depletion", depletion)):
            expected = float(row[name])
            if not math.isfinite(expected) or expected <= 0:
                raise ValueError("Invalid published annual value: " + name)
            maximum = max(maximum, abs(observed - expected))
            if abs(observed - expected) > 1e-10 * max(1, abs(expected)):
                raise ValueError("Native annual series differs: " + name)
    return {"annual_rows": len(annual), "annual_max_abs_diff": maximum,
            "published_series_sha256": rule["series"]["sha256"]}


def evaluate(model, output, rule, directory=None):
    if directory is None:
        subprocess.run([sys.executable, str(HERE / "restore.py"), model, str(output)], check=True)
    with (contextlib.nullcontext(directory) if directory is not None else NativeDirectory(output)) as output:
        saved = json.loads(output.read_bytes("saved-inputs.json"))["files"]

        def unchanged():
            for name, row in saved.items():
                data = output.read_bytes(name)
                if len(data) != row["bytes"] or restore.digest(data) != row["sha256"]:
                    raise ValueError("Saved input changed: " + name)

        unchanged()
        before = output.read_bytes("final.par")
        if restore.digest(before) != rule["source_par_sha256"]:
            raise ValueError("Final PAR differs from the published model")
        saved_objective = par_number(before, "# Objective function value")
        saved_parameters = par_count(before)
        original = reference_rep(output, rule) if rule["mode"] == "reference-rep" else None
        if rule["mode"] not in ("reference-rep", "annual-series"):
            raise ValueError("Unknown native comparison policy")
        if rule["mode"] == "annual-series" and rule.get("annual_policy") != "quarterly_biomass":
            raise ValueError("Annual comparison policy is missing")
        unchanged()
        output.write_new("input.par", before)
        with output.open_input("mfclo64") as (engine_fd, engine_bytes):
            if restore.digest(engine_bytes) != saved["mfclo64"]["sha256"]:
                raise ValueError("Native executable changed before evaluation")
            with output.open_new("mfcl-native.log") as log:
                result = subprocess.run([output.child_file(engine_fd), "bet.frq", "input.par",
                                         "evaluated.par", "-file", "-"], input=CONTROLS, stdout=log,
                                        stderr=subprocess.STDOUT, timeout=1200,
                                        **output.child_kwargs(engine_fd))
        unchanged()
        if output.read_bytes("input.par") != before:
            raise ValueError("Staged final PAR changed")
        if result.returncode not in (0, 3):
            raise ValueError(f"Native evaluation failed for {model}: status {result.returncode}")
        par = output.read_bytes("evaluated.par")
        report = output.read_bytes("plot-evaluated.par.rep")
        if not par or not report:
            raise ValueError("Native PAR or REP is empty")
        if par_count(par) != saved_parameters:
            raise ValueError("Active parameter count differs from the saved model")
        objective = par_number(par, "# Objective function value")
        values = re.findall(r"^\s*Total func\s+([^\s]+)\s*$",
                            output.read_bytes("mfcl-native.log").decode(), re.MULTILINE)
        if not values or not math.isfinite(float(values[0])):
            raise ValueError("Missing finite fitted objective in native log")
        logged = float(values[0])
        if max(abs(objective - saved_objective), abs(logged - saved_objective)) > 1e-6:
            raise ValueError(f"Fitted objective differs: saved={saved_objective}, PAR={objective}, first_log={logged}")
        parity = compare_rep(report, original) if original is not None else compare_annual(report, model, rule)
        parity.update(compare_annual(report, model, rule))
        unchanged()
        receipt = {"case": model, "mode": "outputs-only", "function_evaluation_limit": 1,
                   "controls": CONTROLS.decode().splitlines(), "input_par_sha256": restore.digest(before),
                   "report_sha256": restore.digest(report), "active_parameters": saved_parameters,
                   "saved_objective": saved_objective, "evaluated_objective": objective,
                   "logged_objective": logged, "native_status": result.returncode,
                   "native_inputs_unchanged": True, "mfcl_sha256": saved["mfclo64"]["sha256"], **parity}
        output.write_new("native-check.json", (json.dumps(receipt, indent=2) + "\n").encode())
        print(model + ": native saved-model outputs verified", flush=True)
        return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", help="a saved model ID or all")
    parser.add_argument("output", type=Path, help="a new output directory")
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "amd64"):
        parser.error("Native MFCL requires 64-bit x86 Linux")
    recipe = json.loads(read_bytes(HERE / "package.json"))
    validation = restore.read_json(recipe["validation"])
    closure = restore.read_json(recipe["closure"])
    expected = validation["cases"]
    if set(expected) != {row["model"] for row in closure["models"]}:
        parser.error("Native validation cases differ from saved models")
    if args.case not in expected and args.case != "all":
        parser.error("Choose a model listed in closure.json or all")
    if args.output.exists() or args.output.is_symlink():
        parser.error("Choose a new output directory")
    args.output = args.output.resolve()
    if (args.output == restore.REPO or restore.REPO in args.output.parents
            and restore.REPO / "outputs" not in args.output.parents):
        parser.error("Output inside the checkout must be beneath outputs/")
    selected = expected.items() if args.case == "all" else [(args.case, expected[args.case])]
    if any(rule.get("mode") == "annual-series"
           and rule.get("annual_policy") != "quarterly_biomass" for _, rule in selected):
        parser.error("Annual comparison policy is missing")
    if args.case == "all":
        restore.save_files(args.output, {}, validation["family"] + "-collection")
        with NativeDirectory(args.output) as collection:
            def check(case, rule):
                files = original_files(restore, case)
                with collection.create_child(case) as directory:
                    directory.stage_files(files, case)
                    return evaluate(case, directory.path, rule, directory)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(check, case, rule) for case, rule in selected]
                receipts = [item.result() for item in futures]
            collection.write_new("native-checks.json", (json.dumps(receipts, indent=2) + "\n").encode())

    else:
        evaluate(args.case, args.output, expected[args.case])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, UnicodeError, subprocess.CalledProcessError,
            subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error))
