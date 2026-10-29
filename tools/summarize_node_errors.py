#!/usr/bin/env python3
"""Produce a bounded diagnostic summary from a 10ksim run artifact."""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path


def enrich_results(directory):
    results = json.loads((directory / "node_results.json").read_text())
    for node in results.get("nodes", []):
        if node.get("state") != "failed":
            continue
        path = directory / "node_logs" / (node["node"] + ".log")
        if not path.is_file():
            continue
        for line in path.read_text(errors="replace").splitlines():
            if not line.startswith("NETWORK_LAB_FAILURE "):
                continue
            try:
                failure = json.loads(line.removeprefix("NETWORK_LAB_FAILURE "))
            except (ValueError, TypeError):
                continue
            if isinstance(failure, dict) and all(
                isinstance(failure.get(field), str)
                for field in ("role", "phase", "category", "message")
            ):
                node["failure"] = {field: failure[field] for field in
                                   ("role", "phase", "category", "message")}
                break
    return results


def summarize(directory, results=None):
    results = results if results is not None else enrich_results(directory)
    groups = defaultdict(list)
    missing = 0
    for node in results.get("nodes", []):
        if node.get("state") != "failed":
            continue
        path = directory / "node_logs" / (node["node"] + ".log")
        if not path.is_file():
            missing += 1
            continue
        lines = path.read_text(errors="replace").splitlines()
        failure = node.get("failure")
        errors = [line for line in lines if re.search(r"\b(?:ERR|ERROR|FATAL)\b", line, re.I)]
        if failure:
            sample = (f"phase={failure['phase']} category={failure['category']} "
                      f"message={failure['message']}")[:1000]
        elif errors:
            sample = errors[0][:1000]
        else:
            missing += 1
            continue
        key = re.sub(r"^\S+\s+\d{4}-\d\d-\d\d\s+\S+\s+", "", sample)
        key = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", key)
        key = re.sub(r"address_v4: \[\d+, \d+, \d+, \d+\]", "address_v4: <ip>", key)
        key = re.sub(r'\btid=\d+', 'tid=<id>', key)
        groups[(node.get("group", "unknown"), key)].append((node["node"], sample))
    out = ["## Node diagnostics", "", f"Failed: {results.get('failed', '?')} / {results.get('num_nodes', '?')}; ended: {results.get('ended', 'unknown')}", ""]
    for (role, _), samples in sorted(groups.items(), key=lambda x: (-len(x[1]), x[0]))[:10]:
        name, sample = samples[0]
        # A plain indented block avoids interpreting log content as Markdown.
        out += [f"- {role}: {len(samples)} nodes; example `{name}`:", "", "    " + sample.replace("\t", " "), ""]
    if len(groups) > 10:
        out.append(f"Additional error groups omitted: {len(groups) - 10}.")
    if missing:
        out.append(f"{missing} failed nodes had no readable error line; inspect the full artifact.")
    if not groups and not missing:
        out.append("No failed-node error logs available; inspect the full artifact.")
    return "\n".join(out)


if __name__ == "__main__":
    directory = Path(sys.argv[1])
    results = enrich_results(directory)
    (directory / "node_results.enriched.json").write_text(json.dumps(results, indent=2) + "\n")
    print(summarize(directory, results))
