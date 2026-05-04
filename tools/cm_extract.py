#!/usr/bin/env python3
"""
cm_extract: Lua source → .cm semantic-outline.

The .cm file is a derived view, not a source of truth. Regenerate after
every change to the .lua. Read .cm for orientation; open .lua before editing.

Heuristics target this codebase's idioms:
  - factory-closure pattern: `function newXxxManager(args) ... return mgr end`
  - method assignment: `function tbl:method(args)`
  - section banners: `----- Name` / `---------- Name`
  - signal emission: `fire('signalName', ...)`
  - REAPER calls: `reaper.X(...)`
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass, field


COMMENT_RE = re.compile(r"^\s*--\s?(.*)$")
LOAD_MODULE_RE = re.compile(r"""loadModule\(\s*['"]([^'"]+)['"]\s*\)""")
SECTION_RE = re.compile(r"^(\s*)-{5,}\s+(\S.*?)\s*$")
FACTORY_RE = re.compile(r"^function\s+(new[A-Z]\w*)\s*\(([^)]*)\)")
LOCAL_FN_RE = re.compile(r"^(\s*)local\s+function\s+(\w+)\s*\(([^)]*)\)")
METHOD_RE = re.compile(r"^(\s*)function\s+(\w+):(\w+)\s*\(([^)]*)\)")
DOT_FN_RE = re.compile(r"^(\s*)function\s+(\w+)\.(\w+)\s*\(([^)]*)\)")
LOCAL_DECL_RE = re.compile(r"^(\s*)local\s+(\w+)(?:\s*=\s*(.+?))?\s*(?:--.*)?$")
FIRE_RE = re.compile(r"""\bfire\(\s*['"]([^'"]+)['"]""")
REAPER_RE = re.compile(r"\breaper\.(\w+)")
RETURN_TBL_RE = re.compile(r"^\s*return\s+(\w+)\s*$")
INVERSE_RE = re.compile(
    r"for\s+\w+\s*,\s*\w+\s+in\s+pairs\(\s*(\w+)\s*\)\s+do\s+(\w+)\[\w+\]\s*=\s*\w+\s+end"
)
# --@cm:KIND BODY  or  --@cm?:KIND BODY
CM_ANN_RE = re.compile(r"^\s*--@cm(\??):(\w+)\s+(.*?)\s*$")
EMITS_BODY_RE = re.compile(r"^(\w+)\s*(?:--\s*(.*))?$")

ATTACH_GAP = 3   # max line gap between an annotation and the element it attaches to


Annotation = tuple[str, str, bool]   # (kind, body, has_question)


@dataclass
class Block:
    indent: int
    kind: str               # 'fn', 'method', 'factory'
    name: str
    owner: str = ''         # for methods: the table (e.g. 'mm')
    args: str = ''
    line: int = 0
    doc: list[str] = field(default_factory=list)
    annotations: list[Annotation] = field(default_factory=list)


@dataclass
class Decl:
    name: str
    init: str = ''
    line: int = 0
    inline_doc: str = ''
    annotations: list[Annotation] = field(default_factory=list)


@dataclass
class CmFile:
    module: str
    src: Path
    loc: int
    sha: str
    deps: list[str] = field(default_factory=list)
    factories: list[Block] = field(default_factory=list)
    module_fns: list[Block] = field(default_factory=list)
    module_api: list[Block] = field(default_factory=list)   # function TBL.X(...)
    module_consts: list[Decl] = field(default_factory=list)
    private_fns: list[Block] = field(default_factory=list)   # inside factory
    private_state: list[Decl] = field(default_factory=list)
    methods: list[Block] = field(default_factory=list)       # mm:foo
    method_owner: str = ''
    sections: list[tuple[int, int, str]] = field(default_factory=list)  # (line, indent, label)
    signals: list[str] = field(default_factory=list)
    reaper_calls: list[str] = field(default_factory=list)
    module_annotations: list[Annotation] = field(default_factory=list)
    factory_annotations: list[Annotation] = field(default_factory=list)
    shape_annotations: list[Annotation] = field(default_factory=list)
    signal_payloads: dict[str, str] = field(default_factory=dict)
    pending_annotations: list[tuple[int, str, str, bool]] = field(default_factory=list)


def collect_doc(lines: list[str], i: int) -> list[str]:
    """Walk backwards from line i collecting contiguous comment lines.
    Skips --@cm: annotation lines (they're collected separately and rendered
    as structured entries; including them here would duplicate the content)."""
    out: list[str] = []
    j = i - 1
    while j >= 0:
        if CM_ANN_RE.match(lines[j]):
            j -= 1
            continue
        m = COMMENT_RE.match(lines[j])
        if not m:
            break
        text = m.group(1).rstrip()
        if not text or text.startswith('-'):  # skip banner residue / empty
            break
        out.append(text)
        j -= 1
    return list(reversed(out))


def short_sha(path: Path) -> str:
    try:
        r = subprocess.run(
            ['git', 'log', '-1', '--format=%h', '--', str(path)],
            capture_output=True, text=True, cwd=path.parent,
        )
        return r.stdout.strip() or 'untracked'
    except Exception:
        return 'unknown'


def parse(path: Path) -> CmFile:
    text = path.read_text()
    lines = text.splitlines()

    cm = CmFile(
        module=path.stem,
        src=path,
        loc=len(lines),
        sha=short_sha(path),
    )

    in_factory = False
    factory_body_indent: int | None = None    # the indent of factory's direct children

    for i, raw in enumerate(lines):
        if not raw.strip():
            continue

        # --@cm[?]?:KIND BODY  — accumulate; attached after parse by line proximity
        ma = CM_ANN_RE.match(raw)
        if ma:
            has_q = ma.group(1) == '?'
            kind, body = ma.group(2), ma.group(3)
            cm.pending_annotations.append((i + 1, kind, body, has_q))
            if kind == 'emits':
                em = EMITS_BODY_RE.match(body)
                if em:
                    cm.signal_payloads[em.group(1)] = (em.group(2) or '').strip()
            continue

        # loadModule deps
        for m in LOAD_MODULE_RE.finditer(raw):
            if m.group(1) not in cm.deps:
                cm.deps.append(m.group(1))

        # section banners: line is exactly "----- Name" (5+ dashes, then label, EOL)
        ms = SECTION_RE.match(raw)
        if ms:
            cm.sections.append((i + 1, len(ms.group(1)), ms.group(2)))

        # factory definition
        mf = FACTORY_RE.match(raw)
        if mf:
            blk = Block(indent=0, kind='factory', name=mf.group(1),
                        args=mf.group(2).strip(), line=i + 1,
                        doc=collect_doc(lines, i))
            cm.factories.append(blk)
            in_factory = True
            factory_body_indent = None
            continue

        # First indented non-blank line inside the factory sets the body indent.
        # Subsequent @state filters use exact equality with this indent.
        if in_factory and factory_body_indent is None:
            stripped = raw.lstrip()
            if stripped and not stripped.startswith('--'):
                indent = len(raw) - len(stripped)
                if indent > 0:
                    factory_body_indent = indent

        # method on table (colon = self-receiver)
        mm = METHOD_RE.match(raw)
        if mm:
            indent = len(mm.group(1))
            blk = Block(indent=indent, kind='method',
                        owner=mm.group(2), name=mm.group(3),
                        args=mm.group(4).strip(), line=i + 1,
                        doc=collect_doc(lines, i))
            cm.methods.append(blk)
            if not cm.method_owner:
                cm.method_owner = blk.owner
            continue

        # module-table function (dot = no self): function util.assign(...)
        md_fn = DOT_FN_RE.match(raw)
        if md_fn and not in_factory:
            blk = Block(indent=0, kind='method',
                        owner=md_fn.group(2), name=md_fn.group(3),
                        args=md_fn.group(4).strip(), line=i + 1,
                        doc=collect_doc(lines, i))
            cm.module_api.append(blk)
            continue

        # local function
        ml = LOCAL_FN_RE.match(raw)
        if ml:
            indent = len(ml.group(1))
            blk = Block(indent=indent, kind='fn', name=ml.group(2),
                        args=ml.group(3).strip(), line=i + 1,
                        doc=collect_doc(lines, i))
            if indent == 0:
                cm.module_fns.append(blk)
            else:
                cm.private_fns.append(blk)
            continue

        # signals
        for m in FIRE_RE.finditer(raw):
            if m.group(1) not in cm.signals:
                cm.signals.append(m.group(1))

        # reaper.X
        for m in REAPER_RE.finditer(raw):
            name = m.group(1)
            if name not in cm.reaper_calls:
                cm.reaper_calls.append(name)

        # private state: `local foo` at exactly the factory body indent,
        # before the first method. Excludes loop-locals nested in helpers.
        if (in_factory and not cm.methods
                and factory_body_indent is not None):
            md = LOCAL_DECL_RE.match(raw)
            if md and not LOCAL_FN_RE.match(raw):
                indent = len(md.group(1))
                if indent == factory_body_indent:
                    init = (md.group(3) or '').strip()
                    inline_doc = ''
                    if '--' in raw and not init.startswith("'"):
                        # take inline doc that follows declaration
                        tail = raw.split('--', 1)[1].strip()
                        if tail and not init.endswith(tail):
                            inline_doc = tail
                    if len(init) > 60:
                        init = init[:57] + '...'
                    cm.private_state.append(Decl(name=md.group(2), init=init,
                                                  line=i + 1, inline_doc=inline_doc))

        # module-level constants (indent 0, before factory)
        if not in_factory:
            md = LOCAL_DECL_RE.match(raw)
            if md and md.group(1) == '' and md.group(3):
                init = md.group(3).strip()
                if len(init) > 80:
                    init = init[:77] + '...'
                cm.module_consts.append(Decl(name=md.group(2), init=init, line=i + 1))

        # Loop-built inverse: `for k,v in pairs(Y) do X[v]=k end`
        # Rewrites a prior @const X = {} entry to "inverse of Y" (module or private).
        mi = INVERSE_RE.search(raw)
        if mi:
            src_tbl, dst_tbl = mi.group(1), mi.group(2)
            for d in cm.module_consts:
                if d.name == dst_tbl and d.init == '{}':
                    d.init = f'-- inverse of {src_tbl}'
                    break
            for d in cm.private_state:
                if d.name == dst_tbl and d.init == '{}':
                    d.init = f'-- inverse of {src_tbl}'
                    break

    attach_annotations(cm)
    return cm


def attach_annotations(cm: CmFile) -> None:
    """Attach pending annotations to nearest following structural element.

    Rules:
      - shape  → always rendered standalone (under # Shapes), never attached.
      - emits  → consumed into cm.signal_payloads during parse; not attached.
      - other (contract, invariant) → attach to next element with line ≥ ann_line
        and (target.line - ann_line) ≤ ATTACH_GAP. Otherwise drop into module_annotations
        (if before factory) or factory_annotations (if inside, unattached).
    """
    targets: list = []
    targets.extend(cm.module_consts)
    targets.extend(cm.private_state)
    targets.extend(cm.factories)
    targets.extend(cm.methods)
    targets.extend(cm.module_fns)
    targets.extend(cm.module_api)
    targets.extend(cm.private_fns)
    targets.sort(key=lambda t: t.line)

    factory_line = cm.factories[0].line if cm.factories else 10**9

    for ann_line, kind, body, has_q in cm.pending_annotations:
        if kind == 'emits':
            continue
        if kind == 'shape':
            cm.shape_annotations.append((kind, body, has_q))
            continue
        target = None
        for t in targets:
            if t.line >= ann_line:
                target = t
                break
        if target and target.line - ann_line <= ATTACH_GAP:
            target.annotations.append((kind, body, has_q))
        elif ann_line < factory_line:
            cm.module_annotations.append((kind, body, has_q))
        else:
            cm.factory_annotations.append((kind, body, has_q))


def fmt_args(args: str) -> str:
    return f"({args})" if args else "()"


def fmt_ann(ann: Annotation) -> str:
    kind, body, q = ann
    mark = '?' if q else ''
    return f"@cm{mark}:{kind}  {body}"


def emit_annotations(out: list[str], anns: list[Annotation], indent: str) -> None:
    for ann in anns:
        out.append(f"{indent}{fmt_ann(ann)}")


def emit(cm: CmFile) -> str:
    out: list[str] = []
    add = out.append

    add(f"@module {cm.module}  src={cm.src.name}  loc={cm.loc}  sha={cm.sha}")
    if cm.deps:
        add(f"@deps {', '.join(cm.deps)}")
    add('')

    if cm.module_annotations:
        add("# Invariants & contracts (module)")
        emit_annotations(out, cm.module_annotations, '  ')
        add('')

    if cm.module_consts:
        add("# Module-level constants")
        for d in cm.module_consts:
            if d.init.startswith('--'):
                add(f"  @const {d.name}   {d.init}")
            else:
                add(f"  @const {d.name} = {d.init}")
            emit_annotations(out, d.annotations, '      ')
        add('')

    if cm.module_fns:
        add("# Module-level functions (private)")
        for f in cm.module_fns:
            line = f"  @fn {f.name}{fmt_args(f.args)}"
            if f.doc:
                line += f"   -- {' '.join(f.doc)[:80]}"
            add(line)
            emit_annotations(out, f.annotations, '      ')
        add('')

    if cm.module_api:
        # Resolve `local M = <alias>` to <alias>.X for legibility.
        alias_target: str | None = None
        for d in cm.module_consts:
            if d.init and d.init.isidentifier():
                alias_target = d.init
                break
        owners = sorted({(alias_target if a.owner == 'M' and alias_target else a.owner)
                         for a in cm.module_api})
        owner_label = ' / '.join(owners)
        add(f"# Public API ({owner_label}.*)")
        for f in cm.module_api:
            owner = alias_target if (f.owner == 'M' and alias_target) else f.owner
            line = f"  @api {owner}.{f.name}{fmt_args(f.args)}"
            add(line)
            if f.doc:
                for d in f.doc:
                    add(f"      -- {d}")
            emit_annotations(out, f.annotations, '      ')
        add('')

    for fac in cm.factories:
        add(f"@factory {fac.name}{fmt_args(fac.args)}")
        if fac.doc:
            for d in fac.doc:
                add(f"  -- {d}")
        emit_annotations(out, fac.annotations, '  ')
        emit_annotations(out, cm.factory_annotations, '  ')

        if cm.shape_annotations:
            add("")
            add("  # Shapes")
            for ann in cm.shape_annotations:
                _, body, q = ann
                mark = '?' if q else ''
                add(f"    @shape{mark}  {body}")

        if cm.private_state:
            add("")
            add("  # Private state")
            for d in cm.private_state:
                head = f"    @state {d.name}"
                if d.init:
                    head += f" = {d.init}"
                if d.inline_doc:
                    head += f"   -- {d.inline_doc}"
                add(head)
                emit_annotations(out, d.annotations, '        ')

        if cm.private_fns:
            add("")
            add("  # Private functions")
            for f in cm.private_fns:
                line = f"    @fn {f.name}{fmt_args(f.args)}"
                if f.doc:
                    line += f"   -- {' '.join(f.doc)[:90]}"
                add(line)
                emit_annotations(out, f.annotations, '        ')

        if cm.methods:
            add("")
            add(f"  # Public API")
            sections = list(cm.sections)
            for idx, m in enumerate(cm.methods):
                next_line = cm.methods[idx + 1].line if idx + 1 < len(cm.methods) else 10**9
                # Banner classification by indent:
                #   indent <= method indent → sibling divider (emit before @api)
                #   indent  > method indent → sub-section inside this method's body
                pre, inside = [], []
                rest = []
                for sec in sections:
                    line, sec_indent, label = sec
                    if line >= next_line:
                        rest.append(sec); continue
                    if sec_indent <= m.indent:
                        if line < m.line:
                            pre.append(sec)
                        else:
                            # banner at same level but after method start: belongs to next
                            rest.append(sec)
                    else:
                        if line >= m.line:
                            inside.append(sec)
                        else:
                            pre.append(sec)
                sections = rest
                for sec in pre:
                    if sec[2] not in ('PRIVATE', 'PUBLIC', 'Utils'):
                        add(f"    -- {sec[2]}")
                add(f"    @api {m.owner}:{m.name}{fmt_args(m.args)}")
                if m.doc:
                    for d in m.doc:
                        add(f"        -- {d}")
                emit_annotations(out, m.annotations, '        ')
                for sec in inside:
                    add(f"        · {sec[2]}")

        if cm.signals:
            add("")
            add("  # Signals emitted (via util.installHooks)")
            for s in cm.signals:
                payload = cm.signal_payloads.get(s)
                if payload:
                    add(f"    @emits {s}   -- {payload}")
                else:
                    add(f"    @emits {s}")

        if cm.reaper_calls:
            add("")
            add("  # REAPER API surface")
            # group reaper calls by prefix
            groups: dict[str, list[str]] = {}
            for r in cm.reaper_calls:
                key = r.split('_', 1)[0] if '_' in r else r
                groups.setdefault(key, []).append(r)
            for key, names in groups.items():
                add(f"    @reaper {', '.join(names)}")

    return '\n'.join(out) + '\n'


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: cm_extract.py <lua-file> [<out-dir>]", file=sys.stderr)
        return 2
    src = Path(argv[1]).resolve()
    out_dir = Path(argv[2]).resolve() if len(argv) > 2 else src.parent / 'cm'
    out_dir.mkdir(parents=True, exist_ok=True)
    cm = parse(src)
    out_path = out_dir / (src.stem + '.cm')
    out_path.write_text(emit(cm))
    print(out_path)
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
