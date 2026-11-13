#!/usr/bin/env python3
"""Every public item a package exports is on the page that documents it.

A package's surface is what `moon info` writes into `pkg.generated.mbti`; the pages
are generated from the sources, and only from the files the section table names. So
the two can disagree in a way nothing else notices: a declaration in a file no page
reads is exported and undocumented, while every other check stays green.

This compares them. For each package the script takes the interface file's public
declarations, finds the pages whose files live in that package, and reports each name
that only appears in a file no page reads. A package with exports and no page at all
is reported too.

Run it after `moon info`, which is what produces the interface files.
"""
import html
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))

from sections import SECTIONS  # noqa: E402  (same directory)

SRC = ROOT / "src"
DOCS = ROOT / "docs"

# `pub fn`, `pub(all) struct`, `pub(open) trait`, `pub let`, `pub enum`, `pub type`,
# `pub async fn`, and the `suberror` form. `pub impl` lines are derivations rather
# than declarations of a surface, so they are not rows on a page.
DECL = re.compile(
    r"^pub(?:\([a-z]+\))?\s+(?:async\s+)?(fn|struct|enum|type|let|suberror|trait)\s+(.+)$"
)
TYPE_KINDS = ("struct", "enum", "type", "suberror", "trait")
TEST_SUFFIX = ("_test.mbt", "_wbtest.mbt")


def decl_names(lines):
    """`(kind, name)` for every declaration in `lines` that names something.

    The same reader serves the interface file and the sources, which differ only in
    how much of a line follows the name.
    """
    decls = []
    for line in lines:
        m = DECL.match(line.strip())
        if not m:
            continue
        kind, rest = m.group(1), m.group(2).lstrip()
        # A generic declaration puts its type parameters first: `pub fn[T : Eq] f`.
        if rest.startswith("["):
            depth = 0
            for at, ch in enumerate(rest):
                depth += ch == "["
                depth -= ch == "]"
                if depth == 0:
                    rest = rest[at + 1:].lstrip()
                    break
        if kind == "fn":
            name = rest.split("(")[0].strip()
        elif kind == "let":
            name = rest.split(":")[0].strip()
        else:
            name = rest.split("{")[0].split("=")[0].split(":")[0].strip()
        name = name.split("[")[0].strip()
        if name:
            decls.append((kind, name))
    return decls


def item_names(mbti_path):
    """The names a package exports, from its `pkg.generated.mbti`.

    A method of a type that is not itself exported is dropped: promoting a trait
    method on a private type exposes the method, not a surface a reader can name.
    """
    decls = decl_names(mbti_path.read_text(encoding="utf-8").splitlines())
    types = {name for kind, name in decls if kind in TYPE_KINDS}
    out = []
    for kind, name in decls:
        owner = name.split("::")[0] if "::" in name else None
        if owner and owner not in types:
            continue
        out.append((kind, name))
    return out


def source_names(path):
    """The declarations a source file exports.

    Used for a package that has no interface file: `moon info` writes one per package
    only for the canonical backend, so a native-only package has none on disk.
    """
    return decl_names(path.read_text(encoding="utf-8").splitlines())


def page_text(path):
    """What a page says in its signature cells, with the markup taken off."""
    raw = path.read_text(encoding="utf-8")
    cells = re.findall(r'<code class="sig">(.*?)</code>', raw, re.S)
    return html.unescape(re.sub(r"<[^>]+>", "", " ".join(cells)))


def package_dirs():
    """Every package under `src` that is part of the surface.

    Examples are programs rather than packages a caller imports, and `internal/` is
    private to this module by convention, so neither is documented. The root package
    is returned as `SRC` itself: it re-exports names that are documented where they
    live, so it is checked against every page rather than against its own.
    """
    out = []
    for pkg in sorted(SRC.rglob("moon.pkg")):
        d = pkg.parent
        parts = d.relative_to(SRC).parts
        if parts and ("examples" in parts or parts[0] == "internal"):
            continue
        out.append(d)
    return out


def section_files():
    """The source file each page reads: `{page: [file, …]}`."""
    out = {}
    for key, files, _title, _doc in SECTIONS:
        paths = files if isinstance(files, tuple) else (files,)
        out[DOCS / "pkg" / f"{key}.html"] = [SRC / rel for rel in paths]
    return out


def main():
    files_of = section_files()
    for page in files_of:
        if not page.exists():
            print(f"missing page: {page.relative_to(ROOT).as_posix()}")
            return 1
    pages_of_dir = {}
    for page, files in files_of.items():
        for f in files:
            pages_of_dir.setdefault(f.parent, set()).add(page)

    missing = []
    for d in package_dirs():
        mbti = d / "pkg.generated.mbti"
        sources = [
            f
            for f in sorted(d.glob("*.mbt"))
            if not f.name.endswith(TEST_SUFFIX)
        ]
        names = (
            item_names(mbti)
            if mbti.exists()
            else [n for f in sources for n in source_names(f)]
        )
        if not names:
            continue
        if d == SRC:
            # The root package exports names that belong to the packages they live
            # in, so any page may be the one that documents a name.
            pages = set(files_of)
        else:
            pages = pages_of_dir.get(d, set())
        if not pages:
            missing.append((d, "no page documents this package"))
            continue
        documented = " ".join(page_text(p) for p in pages if p.exists())
        read = {f for page in pages for f in files_of[page]}
        unread = [f for f in sources if f not in read]
        elsewhere = " ".join(
            f.read_text(encoding="utf-8") for f in unread if f.exists()
        )
        for kind, name in names:
            if name in documented:
                continue
            if name in elsewhere:
                missing.append((d, f"{kind} {name}"))

    for d, what in missing:
        print(f"missing: {d.relative_to(ROOT).as_posix()}: {what}")
    if missing:
        print(f"{len(missing)} declarations are exported by a file no page reads")
        return 1
    print("every public item of every package is on a page")
    return 0


if __name__ == "__main__":
    sys.exit(main())
