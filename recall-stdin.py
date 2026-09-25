#!/usr/bin/env python3
"""Fan-out recall with the query on stdin, not argv.

`openzoo-ingest recall` (bin/openzoo-ingest) joins every remaining positional
argument into the query. It has no stdin, `-`, or `--stdin` form, so invoking
it would publish the query on cmdline for the whole call. The program's
`main` is guarded by `__name__ == "__main__"`, so this loads it as a library
and calls `recall()` in-process. Only the binary path and top_k are argv.
"""

import importlib.util
import json
import os
import sys


def load_ingest(bin_path):
    real = os.path.realpath(bin_path)
    try:
        with open(real, "r", encoding="utf-8") as fh:
            source = fh.read()
    except OSError as exc:
        raise RuntimeError(f"openzoo-ingest: cannot read {real}: {exc}") from exc
    if 'if __name__' not in source or "main(sys.argv" not in source:
        raise RuntimeError("openzoo-ingest: recall entry is not import-safe")
    spec = importlib.util.spec_from_file_location("openzoo_ingest_cli", real)
    if spec is None or spec.loader is None:
        raise RuntimeError("openzoo-ingest: cannot load recall")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not hasattr(module, "recall"):
        raise RuntimeError("openzoo-ingest: recall() is missing")
    return module


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("recall-stdin: usage: recall-stdin.py INGEST_BIN TOP_K\n")
        return 2
    try:
        top_k = int(argv[2])
    except ValueError:
        sys.stderr.write("recall-stdin: top_k is not an integer\n")
        return 2
    query = sys.stdin.read()
    module = load_ingest(argv[1])
    result = module.recall(query, top_k)
    sys.stdout.write(json.dumps(result) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:
        sys.stderr.write(f"openzoo-ingest: {exc}\n")
        sys.exit(1)
