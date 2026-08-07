#!/usr/bin/env python3
"""Static checks for the console's ES modules — run before deploying a console change.

There is no Node in this project, and `new Function(code)` can't parse `import`/`export`, so this
catches the mistakes that would otherwise only show up as a blank view in the browser:

  1. a name used in one module but owned by another and never imported  (ReferenceError at runtime,
     often only on a code path you didn't click — e.g. the list layout)
  2. a name in an `export {...}` / `expose({...})` list with no top-level definition in that file
     (SyntaxError / ReferenceError at load, breaking the whole console)
  3. an import of a name the target module doesn't export (SyntaxError at load)

Usage:  python3 scripts/check-console-modules.py        # exits non-zero if anything is wrong
"""
import glob
import os
import re
import sys

JS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'console', 'js')

TOP_LEVEL = re.compile(
    r'(?:^|;)(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)'
    r'|^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=(?!>)', re.M)

# Names the browser provides, plus the two globals the vendored xterm bundle defines.
BROWSER = set('''window document location localStorage sessionStorage console fetch setTimeout
clearTimeout setInterval clearInterval requestAnimationFrame queueMicrotask structuredClone
Promise JSON Object Array String Number Math Date Set Map WeakMap RegExp Error TypeError
URL URLSearchParams navigator matchMedia crypto atob btoa Intl Boolean Symbol BigInt Proxy Reflect
Uint8Array Int8Array Float64Array ArrayBuffer DataView TextEncoder TextDecoder
EventSource WebSocket FormData Blob File FileReader Image Audio AbortController Event CustomEvent
MutationObserver ResizeObserver IntersectionObserver getComputedStyle
encodeURIComponent decodeURIComponent encodeURI decodeURI isNaN isFinite parseInt parseFloat
alert confirm prompt Terminal FitAddon'''.split())


def top_level_names(code):
    names = {m.group(1) or m.group(2) for m in TOP_LEVEL.finditer(code)}
    for line in code.split('\n'):                      # let a=1, b=2, c=3
        m = re.match(r'^(?:export\s+)?(?:const|let|var)\s+(.+)$', line)
        if m:
            for part in m.group(1).split(','):
                nm = re.match(r'\s*([A-Za-z_$][\w$]*)\s*=(?!>)', part)
                if nm:
                    names.add(nm.group(1))
    return {n for n in names if n}


def imports_of(code):
    """{name: module_path} for every `import { a, b } from '...'` in the file."""
    out = {}
    for names, path in re.findall(r"^import \{([^}]*)\} from '([^']+)';", code, re.M):
        for n in names.split(','):
            if n.strip():
                out[n.strip()] = path
    return out


def listed(code, pattern):
    out = set()
    for grp in re.findall(pattern, code, re.M):
        out |= {x.strip() for x in grp.split(',') if x.strip()}
    return out


def main():
    files = {os.path.relpath(f, JS_DIR): open(f).read()
             for f in glob.glob(os.path.join(JS_DIR, '**', '*.js'), recursive=True)}
    if not files:
        print(f'no modules found under {JS_DIR}', file=sys.stderr)
        return 1

    defs = {f: top_level_names(c) for f, c in files.items()}
    owner = {}
    for f, names in defs.items():
        for n in names:
            owner.setdefault(n, f)

    problems = []

    for f, code in sorted(files.items()):
        local, imported = defs[f], imports_of(code)
        exported = listed(code, r'^export \{([^}]*)\};')
        exposed = listed(code, r'^expose\(\{([^}]*)\}\)')
        exported |= set(re.findall(r'^export (?:const|let|var|function|async function)\s+([\w$]+)', code, re.M))

        # 1. used here, owned elsewhere, not imported. Deliberately over-approximate: scan the raw
        #    text (template literals hold real calls) — a spurious import of a real symbol is
        #    harmless, a missing one is a runtime crash.
        used = set(re.findall(r'(?<![\w$.])([A-Za-z_$][\w$]*)\s*\(', code))
        used |= set(re.findall(r'(?<![\w$.])([A-Z][A-Z0-9_]{2,})(?![\w$])', code))
        for n in sorted(used):
            o = owner.get(n)
            if o and o != f and n not in local and n not in imported and n not in BROWSER:
                problems.append(f'{f}: uses "{n}" but never imports it (defined in {o})')

        # 2. exported / exposed names must exist at top level here
        for n in sorted(exported | exposed):
            if n not in local and n not in imported:
                kind = 'exports' if n in exported else 'exposes'
                problems.append(f'{f}: {kind} "{n}" which has no top-level definition here')

        # 3. imports must match what the target module actually exports
        for n, path in sorted(imported.items()):
            target = os.path.normpath(os.path.join(os.path.dirname(f), path))
            if target not in files:
                problems.append(f'{f}: imports from "{path}" which does not exist')
                continue
            tcode = files[target]
            t_exports = listed(tcode, r'^export \{([^}]*)\};')
            t_exports |= set(re.findall(r'^export (?:const|let|var|function|async function)\s+([\w$]+)', tcode, re.M))
            if n not in t_exports:
                problems.append(f'{f}: imports "{n}" from {target}, which does not export it')

    for p in problems:
        print('FAIL ' + p)
    if problems:
        print(f'\n{len(problems)} problem(s) in {len(files)} modules')
        return 1
    print(f'ok — {len(files)} modules, imports/exports consistent')
    return 0


if __name__ == '__main__':
    sys.exit(main())
