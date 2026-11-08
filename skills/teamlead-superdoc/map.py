#!/usr/bin/env python3
"""superdoc map: the link graph of a project's superdoc tree, and what is wrong with it.

  map.py [--doc DIR]                     structure (per folder: each page, links out and in) + findings
  map.py [--doc DIR] --check             findings and the summary line only (what hooks and agents run)
  map.py [--doc DIR] --links-to PAGE     every link that points at PAGE, as path:line -> target
  map.py [--doc DIR] --links-from PAGE   every link PAGE contains, as path:line -> target

Output is plain, one finding per line:

  DANGLING  path:line -> target#anchor  (file missing|anchor missing)
  ORPHAN    path  (no inbound links)
  OK|FAIL   N pages, M links, D dangling, O orphan

Exit 1 when there is a dangling link, else 0 (orphans are warnings). A project with no superdoc:
a one-line note, exit 0. Exit 2 on a usage error.

Pages are the .md files under the doc root plus CLAUDE.md (found from the repo root, so any
subdirectory or linked worktree works). The doc root is asked of lint.sh --print-doc-root, the one
copy of that logic. Links are `[text](target)`, `[text](target#anchor)`, `(#anchor)` and
`[ref]: target`; http(s)/mailto and other schemes are ignored, as is anything in a fenced block or
an inline code span. Anchors are matched against the target's headings with GitHub-style slugs
(lowercase, punctuation dropped except - and _, spaces to -, repeats get -1, -2, ...) and its
explicit `<a name=..>` / `id=".."` anchors. An `@<doc>/page.md` force-load line in CLAUDE.md counts
as an inbound link (those pages have no markdown link) but is not counted in M and is never a
DANGLING (lint.sh already reports a dangling @-ref). Not orphans: CLAUDE.md and the README.md at
the doc root or repo root. Links to a page from itself do not count as inbound.
"""
import os
import re
import subprocess
import sys
from urllib.parse import unquote

LINK = re.compile(
    r'!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*(<[^>]*>|(?:[^()\s]|\([^()\s]*\))*)'
    r'(?:\s+(?:"[^"]*"|\'[^\']*\'))?\s*\)')
REFDEF = re.compile(r'^ {0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)')
SCHEME = re.compile(r'^(?:[a-zA-Z][a-zA-Z0-9+.\-]*:|//)')
FENCE = re.compile(r'^ {0,3}(`{3,}|~{3,})')
HEADING = re.compile(r'^ {0,3}#{1,6}[ \t]+(.*?)[ \t]*#*[ \t]*$')
CODESPAN = re.compile(r'(`+)(?:(?!\1).)+?\1')
EXPLICIT = re.compile(r'''<a\s[^>]*?\bname\s*=\s*["']?([^"'\s>]+)|\bid\s*=\s*["']([^"']+)["']''', re.I)


def die(msg, code=2):
    sys.stderr.write('map.py: %s\n' % msg)
    sys.exit(code)


def prose_lines(path):
    """(lineno, text) of every line outside fenced code blocks, inline code spans blanked."""
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            lines = f.read().splitlines()
    except OSError:
        return
    fence = None
    for n, line in enumerate(lines, 1):
        m = FENCE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and line.strip(' \t')[len(m.group(1)):].strip() == '':
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        yield n, CODESPAN.sub(lambda x: ' ' * len(x.group(0)), line)


def slug(text):
    text = re.sub(r'!?\[([^\]]*)\]\([^)]*\)', r'\1', text)   # a link in a heading: its text
    text = re.sub(r'<[^>]+>', '', text).strip().lower()
    return re.sub(r'[^\w\- ]', '', text).replace(' ', '-')


_anchors = {}


def anchors_of(path):
    if path not in _anchors:
        seen, out = {}, set()
        for _, line in prose_lines(path):
            m = HEADING.match(line)
            if m:
                s = slug(m.group(1))
                k = seen.get(s, 0)
                seen[s] = k + 1
                out.add(s if k == 0 else '%s-%d' % (s, k))
            for e in EXPLICIT.finditer(line):
                out.add((e.group(1) or e.group(2)).lower())
        _anchors[path] = out
    return _anchors[path]


def repo_root():
    try:
        r = subprocess.run(['git', 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return os.path.realpath(r.stdout.strip())
    except OSError:
        pass
    return os.path.realpath(os.getcwd())


def doc_root(root, given):
    lint = os.path.join(os.path.dirname(os.path.realpath(__file__)), 'lint.sh')
    cmd = ['bash', lint] + (['--doc', given] if given else []) + ['--print-doc-root']
    try:
        r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    except OSError:
        return ''
    return r.stdout.strip().splitlines()[0] if r.returncode == 0 and r.stdout.strip() else ''


def collect(root, doc):
    pages = []
    for d, dirs, files in os.walk(os.path.join(root, doc)):
        dirs[:] = sorted(x for x in dirs if not x.startswith('.') and x != 'node_modules')
        pages += [os.path.relpath(os.path.join(d, f), root) for f in sorted(files) if f.lower().endswith('.md')]
    if os.path.isfile(os.path.join(root, 'CLAUDE.md')):
        pages.append('CLAUDE.md')
    return sorted(set(pages))


def parse(root, doc, pages):
    """links: (src, line, dest repo-relative or None for outside the repo, anchor, state, kind)"""
    links = []
    refpat = re.compile(r'(?<![`\w])@(' + re.escape(doc) + r'/[^\s)`]+)')
    for src in pages:
        sabs = os.path.join(root, src)
        for n, line in prose_lines(sabs):
            raws = [m.group(1) for m in LINK.finditer(line)]
            rd = REFDEF.match(line)
            if rd:
                raws.append(rd.group(1))
            for raw in raws:
                raw = raw.strip()
                if raw.startswith('<') and raw.endswith('>'):
                    raw = raw[1:-1]
                if not raw or SCHEME.match(raw):
                    continue
                path, _, anchor = raw.partition('#')
                path = unquote(path.split('?', 1)[0])
                anchor = unquote(anchor)
                if path == '':
                    abs_t = sabs
                elif path.startswith('/'):
                    abs_t = os.path.join(root, path.lstrip('/'))
                else:
                    abs_t = os.path.join(os.path.dirname(sabs), path)
                abs_t = os.path.normpath(abs_t)
                rel = os.path.relpath(abs_t, root)
                state = 'ok'
                if not os.path.exists(abs_t):
                    state = 'file missing'
                elif anchor and abs_t.lower().endswith('.md') and os.path.isfile(abs_t) \
                        and anchor.lower() not in anchors_of(abs_t):
                    state = 'anchor missing'
                links.append((src, n, rel, anchor, state, 'link'))
            if src == 'CLAUDE.md':
                for m in refpat.finditer(line):
                    t = m.group(1).rstrip('.,;:')
                    if os.path.exists(os.path.join(root, t)):
                        links.append((src, n, os.path.normpath(t), '', 'ok', 'ref'))
    return links


def show(l):
    src, n, dest, anchor, state, kind = l
    return '%s:%d -> %s%s' % (src, n, dest, '#' + anchor if anchor else '')


def norm_page(root, doc, arg, cwd):
    """PAGE as the user wrote it: relative to the cwd, the repo root or the doc root."""
    cands = [os.path.join(cwd, arg), os.path.join(root, arg), os.path.join(root, doc, arg)]
    for c in cands:
        if os.path.exists(c):
            return os.path.relpath(os.path.normpath(c), root)
    return os.path.relpath(os.path.normpath(cands[1] if not os.path.isabs(arg) else arg), root)


def main(argv):
    mode, page, given, check = 'structure', None, '', False
    a = list(argv)
    while a:
        x = a.pop(0)
        if x in ('-h', '--help'):
            print(__doc__.strip().split('\n\n')[0])
            return 0
        elif x == '--check':
            check = True
        elif x in ('--links-to', '--links-from', '--doc'):
            if not a:
                die('%s needs a value' % x)
            v = a.pop(0)
            if x == '--doc':
                given = v
            else:
                mode, page = x[2:], v
        elif x.startswith('--doc='):
            given = x[6:]
        else:
            die('unknown argument %r (see --help)' % x)
    cwd = os.getcwd()
    root = repo_root()
    doc = doc_root(root, given)
    if not doc or not os.path.isdir(os.path.join(root, doc)):
        print('map: no superdoc in this project, nothing to map')
        return 0
    pages = collect(root, doc)
    links = parse(root, doc, pages)

    if mode in ('links-to', 'links-from'):
        p = norm_page(root, doc, page, cwd)
        if mode == 'links-to':
            hits = [l for l in links if l[2] == p and l[0] != p]
        else:
            hits = [l for l in links if l[0] == p]
        for l in hits:
            extra = '  (%s)' % l[4] if l[4] != 'ok' else ('  (@-ref)' if l[5] == 'ref' else '')
            print(show(l) + extra)
        if not hits and not os.path.exists(os.path.join(root, p)):
            sys.stderr.write('map.py: no such page: %s\n' % p)
        return 0

    inbound = {p: [] for p in pages}
    outbound = {p: [] for p in pages}
    for l in links:
        outbound[l[0]].append(l)
        if l[2] in inbound and l[2] != l[0]:
            inbound[l[2]].append(l)
    dangling = sorted((l for l in links if l[4] != 'ok'), key=lambda l: (l[0], l[1]))
    exempt = {'CLAUDE.md', 'README.md', os.path.join(doc, 'README.md')}
    orphans = [p for p in pages if p not in exempt and not inbound[p]]
    nlinks = sum(1 for l in links if l[5] == 'link')

    if not check:
        folders = {}
        for p in pages:
            folders.setdefault(os.path.dirname(p), []).append(p)
        for d in sorted(folders):
            print('%s/' % d if d else './')
            for p in folders[d]:
                outs = sorted({l[2] + ('#' + l[3] if l[3] else '') for l in outbound[p] if l[2] != p})
                ins = sorted({l[0] for l in inbound[p]})
                print('  %s  out: %s  in: %s' % (os.path.basename(p), ', '.join(outs) or '-', ', '.join(ins) or '-'))
        print()
    for l in dangling:
        print('DANGLING  %s  (%s)' % (show(l), l[4]))
    for p in orphans:
        print('ORPHAN    %s  (no inbound links)' % p)
    print('%-9s %d pages, %d links, %d dangling, %d orphan'
          % ('FAIL' if dangling else 'OK', len(pages), nlinks, len(dangling), len(orphans)))
    return 1 if dangling else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
