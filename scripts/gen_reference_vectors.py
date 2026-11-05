"""Turn the reference decision table into a MoonBit test table.

The table itself comes from the implementation whose behaviour this library has to
match, not from a second implementation written here: see
`scripts/reference/p2c_vector_test.go` for how the file is produced.

Usage:
    python scripts/gen_reference_vectors.py
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "scripts" / "reference" / "p2c_vectors.txt"
TARGET = ROOT / "src" / "balance" / "p2c_vectors_wbtest.mbt"

# A few hundred rows per function: one array literal of thousands of records makes
# a wasm data segment large enough to be worth splitting.
PER_CHUNK = 150


def rows():
    out = []
    for line in SOURCE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        out.append(_parse(line))
    return out


def _parse(line):
    body = line.strip("{}")
    fields = {}
    for part in body.split(","):
        key, value = part.split(":", 1)
        fields[key.strip().strip('"')] = value.strip().strip('"')
    return fields


def num(text):
    """A number as MoonBit spells it: a float always carries a point."""
    value = float(text)
    if value == int(value):
        return f"{int(value)}.0"
    return repr(value)


def main():
    data = rows()
    chunks = [data[i:i + PER_CHUNK] for i in range(0, len(data), PER_CHUNK)]

    lines = [
        "// Generated from scripts/reference/p2c_vectors.txt by",
        "// scripts/gen_reference_vectors.py. Do not edit.",
        "",
        "///|",
        "/// One row of the reference decision table: two nodes' state, and which of",
        "/// them the reference implementation chose.",
        "struct P2cVector {",
        "  lag_a : Double",
        "  inflight_a : Int64",
        "  age_a : Int64",
        "  lag_b : Double",
        "  inflight_b : Int64",
        "  age_b : Int64",
        "  expected : String",
        "}",
        "",
    ]

    for index, chunk in enumerate(chunks, start=1):
        lines.append("///|")
        lines.append(f"fn p2c_vectors_{index}() -> Array[P2cVector] {{")
        lines.append("  [")
        for row in chunk:
            lines.append(
                "    {{ lag_a: {la}, inflight_a: {ia}, age_a: {aa}, "
                "lag_b: {lb}, inflight_b: {ib}, age_b: {ab}, expected: \"{e}\" }},".format(
                    la=num(row["lag_a"]),
                    ia=row["inflight_a"],
                    aa=row["age_a"],
                    lb=num(row["lag_b"]),
                    ib=row["inflight_b"],
                    ab=row["age_b"],
                    e=row["expected"],
                ).replace("{{", "{").replace("}}", "}")
            )
        lines.append("  ]")
        lines.append("}")
        lines.append("")

    lines.append("///|")
    lines.append("/// Every row, in the order the reference emitted them.")
    lines.append("fn p2c_vectors() -> Array[P2cVector] {")
    spread = ", ".join(f"..p2c_vectors_{i}()" for i in range(1, len(chunks) + 1))
    lines.append(f"  [{spread}]")
    lines.append("}")
    lines.append("")

    TARGET.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"wrote {TARGET} ({len(data)} rows in {len(chunks)} chunks)")


if __name__ == "__main__":
    main()
