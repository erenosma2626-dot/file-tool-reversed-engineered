"""Parses every Swift file with tree-sitter and reports syntax errors.

This is not a compiler (no type checking) — it only catches malformed syntax, which is
useful when no Swift toolchain is available.

    pip install tree-sitter tree-sitter-swift
    python3 Scripts/syntax_check.py
"""
import pathlib
import sys

import tree_sitter_swift
from tree_sitter import Language, Parser

parser = Parser(Language(tree_sitter_swift.language()))
root = pathlib.Path(__file__).resolve().parent.parent / "Sources"
problems = 0

for path in sorted(root.rglob("*.swift")):
    source = path.read_bytes()
    tree = parser.parse(source)
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            line = node.start_point[0] + 1
            text = source.splitlines()[line - 1].decode(errors="replace").strip() if line - 1 < len(source.splitlines()) else ""
            kind = "missing " + node.type if node.is_missing else "error"
            print(f"{path.relative_to(root.parent)}:{line}: {kind}: {text[:120]}")
            problems += 1
            continue
        stack.extend(node.children)

print(f"{problems} problem(s)")
sys.exit(1 if problems else 0)
