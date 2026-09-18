"""
A small BASIC interpreter tailored to the specific dialect used in
Island of Secrets' listing.bas (Usborne, 1983/84).

This is NOT a general-purpose BASIC interpreter -- it supports exactly the
statement and function set the verified listing actually uses, so that the
game can be run natively (as opposed to hand-translating ~40 interdependent,
fall-through GOSUB blocks into new Python control flow, which risks
introducing fresh bugs on top of the ones we're already tracking).

Supported statements: LET (with or without the LET keyword), IF/THEN,
FOR/NEXT, GOTO, GOSUB/RETURN, ON...GOSUB, PRINT, INPUT, DATA/READ/RESTORE,
DIM, DEF FN, OPEN/CLOSE/INPUT#/PRINT#, END/STOP, REM, and the game's own
CLS convention (mapped to a screen-clear hook).

Supported functions: INT, RND, ABS, LEN, MID$, LEFT$, RIGHT$, STR$, VAL,
ASC, CHR$, POS, TAB(as a PRINT directive), plus the game's own DEF FN
functions (FNR, FNP, FNS) which are themselves interpreted, not hardcoded.
"""

from __future__ import annotations
import re
import random
from dataclasses import dataclass, field


class BasicError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Expression evaluation
# ---------------------------------------------------------------------------

TOKEN_RE = re.compile(r'''
    \s*(?:
        (?P<string>"[^"]*")
      | (?P<number>\d+\.\d+|\.\d+|\d+)
      | (?P<le><=)
      | (?P<ge>>=)
      | (?P<ne><>)
      | (?P<op>[+\-*/=<>(),;])
      | (?P<ident>FN[A-Z]|[A-Z][A-Z0-9]*\$?)
    )
''', re.VERBOSE)


def tokenize(expr: str):
    tokens = []
    pos = 0
    while pos < len(expr):
        if expr[pos] == ' ':
            pos += 1
            continue
        m = TOKEN_RE.match(expr, pos)
        if not m or m.end() == pos:
            raise BasicError(f"Cannot tokenize at {pos!r} in {expr!r}")
        pos = m.end()
        kind = m.lastgroup
        val = m.group()
        tokens.append((kind, val))
    return tokens


class ExprParser:
    """Recursive-descent parser/evaluator for BASIC expressions."""

    def __init__(self, tokens, interp: 'Interpreter'):
        self.toks = tokens
        self.i = 0
        self.interp = interp

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def next(self):
        t = self.peek()
        self.i += 1
        return t

    def expect(self, val):
        k, v = self.next()
        if v != val:
            raise BasicError(f"Expected {val!r}, got {v!r}")

    # Grammar (lowest to highest precedence):
    # or_expr -> and_expr (OR and_expr)*
    # and_expr -> not_expr (AND not_expr)*
    # not_expr -> NOT not_expr | cmp_expr
    # cmp_expr -> add_expr ((=|<>|<|>|<=|>=) add_expr)*
    # add_expr -> mul_expr ((+|-) mul_expr)*
    # mul_expr -> unary ((*|/) unary)*
    # unary -> -unary | primary
    # primary -> NUMBER | STRING | IDENT | IDENT(args) | (expr)

    def parse(self):
        v = self.or_expr()
        return v

    def or_expr(self):
        v = self.and_expr()
        while self.peek()[1] == 'OR':
            self.next()
            r = self.and_expr()
            v = (1 if (truthy(v) or truthy(r)) else 0)
        return v

    def and_expr(self):
        v = self.not_expr()
        while self.peek()[1] == 'AND':
            self.next()
            r = self.not_expr()
            v = (1 if (truthy(v) and truthy(r)) else 0)
        return v

    def not_expr(self):
        if self.peek()[1] == 'NOT':
            self.next()
            v = self.not_expr()
            return 0 if truthy(v) else 1
        return self.cmp_expr()

    def cmp_expr(self):
        v = self.add_expr()
        while self.peek()[1] in ('=', '<>', '<', '>', '<=', '>='):
            op = self.next()[1]
            r = self.add_expr()
            v = compare(v, op, r)
        return v

    def add_expr(self):
        v = self.mul_expr()
        while self.peek()[1] in ('+', '-'):
            op = self.next()[1]
            r = self.mul_expr()
            if op == '+':
                if isinstance(v, str) or isinstance(r, str):
                    v = to_str(v) + to_str(r)
                else:
                    v = v + r
            else:
                v = num(v) - num(r)
        return v

    def mul_expr(self):
        v = self.unary()
        while self.peek()[1] in ('*', '/'):
            op = self.next()[1]
            r = self.unary()
            v = num(v) * num(r) if op == '*' else num(v) / num(r)
        return v

    def unary(self):
        if self.peek()[1] == '-':
            self.next()
            return -num(self.unary())
        return self.primary()

    def primary(self):
        kind, val = self.peek()
        if kind == 'number':
            self.next()
            return float(val) if ('.' in val) else int(val)
        if kind == 'string':
            self.next()
            return val[1:-1]
        if val == '(':
            self.next()
            v = self.or_expr()
            self.expect(')')
            return v
        if kind == 'ident':
            self.next()
            name = val
            args = None
            if self.peek()[1] == '(':
                self.next()
                args = []
                if self.peek()[1] != ')':
                    args.append(self.or_expr())
                    while self.peek()[1] == ',':
                        self.next()
                        args.append(self.or_expr())
                self.expect(')')
            return self.interp.resolve(name, args)
        raise BasicError(f"Unexpected token {val!r}")


def truthy(v):
    if isinstance(v, str):
        return v != ""
    return num(v) != 0


def num(v):
    if isinstance(v, str):
        raise BasicError(f"Expected number, got string {v!r}")
    return v


def to_str(v):
    if isinstance(v, (int, float)):
        # BASIC STR$ conventions: no decimal for whole numbers, leading
        # space suppressed here for simplicity (original leading-space-for-
        # positive-numbers quirk is handled explicitly where B$ concatenation
        # matters, via str_() below).
        if isinstance(v, float) and v.is_integer():
            v = int(v)
        return str(v)
    return v


def str_(v):
    """BASIC STR$() -- numbers to string."""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v)


def compare(a, op, b):
    if isinstance(a, str) or isinstance(b, str):
        a, b = to_str(a), to_str(b)
    result = {
        '=': a == b, '<>': a != b, '<': a < b, '>': a > b,
        '<=': a <= b, '>=': a >= b,
    }[op]
    return 1 if result else 0


def eval_expr(expr: str, interp: 'Interpreter'):
    toks = tokenize(expr)
    p = ExprParser(toks, interp)
    v = p.parse()
    if p.i != len(p.toks):
        raise BasicError(f"Trailing tokens in {expr!r}: {p.toks[p.i:]}")
    return v


# ---------------------------------------------------------------------------
# Program representation
# ---------------------------------------------------------------------------

@dataclass
class Line:
    num: int
    raw: str
    stmts: list = field(default_factory=list)  # list of raw statement strings


def split_statements(text: str):
    """Split a line's statement body on ':' outside of string literals.

    IF-aware: in this BASIC dialect, everything from an IF up to THEN and
    then every colon-separated statement after THEN to the end of the line
    is that IF's consequent, not a sibling top-level statement (e.g.
    `IF X THEN A:B:C` means "if X then do A, B, and C", not "if X then A;
    unconditionally also do B; unconditionally also do C"). A naive colon
    split would wrongly promote B and C to unconditional siblings.
    """
    out, cur, in_str = [], [], False
    for ch in text:
        if ch == '"':
            in_str = not in_str
        if ch == ':' and not in_str:
            out.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append(''.join(cur))
    raw = [s.strip() for s in out if s.strip() != '']

    # In this dialect an IF always extends to the end of the physical line --
    # there is no way for a sibling unconditional statement to follow an IF
    # on the same line, so once we see one, everything remaining is its
    # (colon-joined) consequent.
    merged = []
    i = 0
    while i < len(raw):
        seg = raw[i]
        if re.match(r'^IF\b', seg, re.IGNORECASE):
            seg = ':'.join(raw[i:])
            merged.append(seg)
            break
        merged.append(seg)
        i += 1
    return merged


def parse_program(source: str):
    lines = {}
    order = []
    for raw in source.splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("'"):
            continue
        m = re.match(r'^(\d+)(.*)$', raw)
        if not m:
            continue
        num = int(m.group(1))
        body = m.group(2)
        # Strip trailing ' VERIFY: ... comment annotations we added during
        # transcription -- but only a ' that occurs OUTSIDE a string literal;
        # an apostrophe inside the game's own text (e.g. "YOU CAN'T ") must
        # not be treated as a comment marker.
        in_str = False
        cut = len(body)
        for idx, ch in enumerate(body):
            if ch == '"':
                in_str = not in_str
            elif ch == "'" and not in_str:
                cut = idx
                break
        body = body[:cut].rstrip()
        lines[num] = Line(num, body, split_statements(body))
        order.append(num)
    order.sort()
    return lines, order


# ---------------------------------------------------------------------------
# Interpreter
# ---------------------------------------------------------------------------

LET_RE = re.compile(r'^(?:LET\s+)?([A-Z][A-Z0-9]*\$?)(\((.*?)\))?\s*=\s*(.*)$', re.DOTALL)


def find_keyword(text, kw):
    """Find `kw` as a whole word outside any string literal. The listing
    sometimes has zero whitespace around keywords (e.g. `=""THEN`), so this
    can't rely on regex \\s+ around the keyword -- just word boundaries."""
    in_str = False
    i = 0
    n = len(text)
    klen = len(kw)
    while i < n:
        ch = text[i]
        if ch == '"':
            in_str = not in_str
            i += 1
            continue
        if not in_str and text[i:i + klen] == kw:
            # Boundary check uses isalpha (not isalnum) deliberately: this
            # dialect's identifiers are a single letter optionally followed
            # by digits (A, F29, ...) or FN+letter, and the tokenizer never
            # merges a digit run with a following letter run into one token
            # (see TOKEN_RE above -- \d+ stops at the first non-digit). So
            # a keyword glued directly onto a digit, e.g. the listing's own
            # `F(29)>0THEN` (line 2100) or `...THEN2000`-style implied-GOTO
            # line numbers, is still two separate tokens and a real keyword
            # boundary -- only an adjacent LETTER (or underscore) can mean
            # this match is actually the middle/suffix of some other
            # identifier (e.g. "THEN" inside a hypothetical "ATHENS").
            before_ok = (i == 0) or not (text[i - 1].isalpha() or text[i - 1] == '_')
            after_idx = i + klen
            after_ok = (after_idx >= n) or not (text[after_idx].isalpha() or text[after_idx] == '_')
            if before_ok and after_ok:
                return i
        i += 1
    return -1


def split_if_then(text):
    idx = find_keyword(text, 'THEN')
    if idx == -1:
        return None
    return text[:idx].strip(), text[idx + 4:].strip()


def split_for_to(text):
    idx = find_keyword(text, 'TO')
    if idx == -1:
        return None
    return text[:idx].strip(), text[idx + 2:].strip()
NEXT_RE = re.compile(r'^NEXT\s*([A-Z][A-Z0-9]*)?$')
ON_RE = re.compile(r'^ON\s+(.*?)\s+GOSUB\s+(.*)$')
DEF_RE = re.compile(r'^DEF\s+(FN[A-Z])\(([A-Z][A-Z0-9]*)\)\s*=\s*(.*)$')
DIM_RE = re.compile(r'^DIM\s+(.*)$')
PRINT_HASH_RE = re.compile(r'^PRINT\s*#\s*(\d+)\s*,\s*(.*)$')
INPUT_HASH_RE = re.compile(r'^INPUT\s*#\s*(\d+)\s*,\s*(.*)$')
OPEN_RE = re.compile(r'^OPEN\s+(.*)$')


class Interpreter:
    def __init__(self, source: str, io, rng_seed=None):
        """
        io: an object providing
            .print(text)      -- append text to current output line (no newline)
            .println(text='') -- append text and end the line
            .input(prompt='')  -- block for a line of user input, return it
            .cls()             -- clear screen
            .save(records)     -- persist a list of numbers for XSAVE
            .load() -> records -- retrieve the list for XLOAD
        """
        self.lines, self.order = parse_program(source)
        self.io = io
        self.rng = random.Random(rng_seed)

        self.num_vars = {}
        self.str_vars = {}
        self.num_arrays = {}   # name -> list, 1-indexed (index 0 unused)
        self.str_arrays = {}
        self.def_fn = {}       # name -> (param, expr)

        self.data_values = []
        self._collect_data()
        self.data_line_index = {}   # line_num -> index into data_values at start of that line
        self._index_data_lines()
        self.data_ptr = 0

        self.gosub_stack = []
        self.for_stack = []
        self.pc = None
        self.stmt_i = 0
        self.running = False
        self.open_files = {}

    # -- DATA handling -------------------------------------------------
    def _collect_data(self):
        for num in self.order:
            for stmt in self.lines[num].stmts:
                if stmt.upper().startswith('DATA'):
                    body = stmt[4:].strip()
                    for item in self._split_data_items(body):
                        self.data_values.append(item)

    def _index_data_lines(self):
        idx = 0
        for num in self.order:
            self.data_line_index[num] = idx
            for stmt in self.lines[num].stmts:
                if stmt.upper().startswith('DATA'):
                    body = stmt[4:].strip()
                    idx += len(self._split_data_items(body))

    @staticmethod
    def _split_data_items(body):
        items, cur, in_str = [], [], False
        for ch in body:
            if ch == '"':
                in_str = not in_str
                continue
            if ch == ',' and not in_str:
                items.append(''.join(cur).strip())
                cur = []
            else:
                cur.append(ch)
        items.append(''.join(cur).strip())
        return items

    # -- variable access (called by ExprParser via resolve) ------------
    def resolve(self, name, args):
        if args is None:
            if name == 'POS':
                # C64-dialect quirk: POS used bare (no parens) in the base
                # listing; other platforms' conversion lines write POS(0).
                # Either way it means "current cursor column".
                return self.io.cursor_col()
            if name.endswith('$'):
                return self.str_vars.get(name, "")
            return self.num_vars.get(name, 0)

        # function or array reference
        upper = name
        if upper == 'INT':
            return int(math_floor(num(args[0])))
        if upper == 'ABS':
            return abs(args[0])
        if upper == 'RND':
            return self.rng.random()
        if upper == 'LEN':
            return len(args[0])
        if upper == 'MID$':
            s = args[0]
            start = int(args[1]) - 1
            if len(args) >= 3:
                ln = int(args[2])
                return s[start:start + ln]
            return s[start:]
        if upper == 'LEFT$':
            return args[0][:int(args[1])]
        if upper == 'RIGHT$':
            n = int(args[1])
            return args[0][-n:] if n > 0 else ""
        if upper == 'STR$':
            return str_(args[0])
        if upper == 'VAL':
            s = args[0].strip()
            m = re.match(r'^[+-]?\d+\.?\d*', s)
            if not m:
                return 0
            g = m.group().lstrip('+')  # Python int()/float() don't accept a leading '+'
            return float(g) if '.' in g else int(g)
        if upper == 'ASC':
            return ord(args[0][0]) if args[0] else 0
        if upper == 'CHR$':
            return chr(int(args[0]))
        if upper == 'POS':
            return self.io.cursor_col()
        if upper == 'TAB':
            # handled specially inside PRINT; if reached here just no-op
            return ""
        if upper in self.def_fn:
            param, expr = self.def_fn[upper]
            saved = self.num_vars.get(param, 0)
            self.num_vars[param] = args[0]
            try:
                v = eval_expr(expr, self)
            finally:
                self.num_vars[param] = saved
            return v

        # array reference
        if name.endswith('$'):
            arr = self.str_arrays.setdefault(name, [""] * 100)
        else:
            arr = self.num_arrays.setdefault(name, [0] * 100)
        i = int(args[0])
        if i >= len(arr):
            arr.extend([("" if name.endswith('$') else 0)] * (i - len(arr) + 10))
        return arr[i]

    def set_scalar(self, name, value):
        if name.endswith('$'):
            self.str_vars[name] = to_str(value) if not isinstance(value, str) else value
        else:
            self.num_vars[name] = value

    def set_array(self, name, index, value):
        if name.endswith('$'):
            arr = self.str_arrays.setdefault(name, [""] * 100)
        else:
            arr = self.num_arrays.setdefault(name, [0] * 100)
        i = int(index)
        if i >= len(arr):
            arr.extend([("" if name.endswith('$') else 0)] * (i - len(arr) + 10))
        arr[i] = value

    # -- run loop --------------------------------------------------------
    def run_from(self, line_num):
        self.pc = line_num
        self.stmt_i = 0
        self.running = True
        while self.running and self.pc is not None:
            if self.pc not in self.lines:
                raise BasicError(f"No such line {self.pc}")
            stmts = self.lines[self.pc].stmts
            if self.stmt_i >= len(stmts):
                nxt = self._next_line(self.pc)
                self.pc = nxt
                self.stmt_i = 0
                continue
            stmt = stmts[self.stmt_i]
            self.stmt_i += 1
            self._exec(stmt)

    def _next_line(self, num):
        i = self.order.index(num)
        return self.order[i + 1] if i + 1 < len(self.order) else None

    def _goto(self, num):
        self.pc = num
        self.stmt_i = 0

    def _gosub(self, num):
        self.gosub_stack.append((self.pc, self.stmt_i))
        self._goto(num)

    def _return(self):
        if not self.gosub_stack:
            raise BasicError("RETURN without GOSUB")
        self.pc, self.stmt_i = self.gosub_stack.pop()

    # -- statement execution ---------------------------------------------
    def _exec(self, stmt):
        u = stmt.upper()

        if u.startswith('REM'):
            return
        if u == 'RETURN':
            self._return()
            return
        if u == 'CLS':
            self.io.cls()
            return
        if u in ('END', 'STOP'):
            self.running = False
            self.pc = None
            return
        if u.startswith('GOTO'):
            self._goto(int(stmt[4:].strip()))
            return
        if u.startswith('GOSUB'):
            self._gosub(int(stmt[5:].strip()))
            return
        if u.startswith('RESTORE'):
            rest = stmt[7:].strip()
            if rest == '':
                self.data_ptr = 0
            else:
                target = int(eval_expr(rest, self))
                self.data_ptr = self.data_line_index.get(target, 0)
            return
        if u.startswith('DATA'):
            return  # collected up-front

        m = ON_RE.match(stmt)
        if m:
            idx_expr, targets = m.groups()
            idx = int(eval_expr(idx_expr, self))
            target_lines = [int(t.strip()) for t in targets.split(',')]
            if 1 <= idx <= len(target_lines):
                self._gosub(target_lines[idx - 1])
            return

        m = DEF_RE.match(stmt)
        if m:
            fname, param, expr = m.groups()
            self.def_fn[fname] = (param, expr)
            return

        m = DIM_RE.match(stmt)
        if m:
            for decl in self._split_data_items(m.group(1)):
                dm = re.match(r'^([A-Z][A-Z0-9]*\$?)\((.*)\)$', decl.strip())
                if dm:
                    name, size_expr = dm.groups()
                    size = int(eval_expr(size_expr.split(',')[0], self))
                    if name.endswith('$'):
                        self.str_arrays[name] = [""] * (size + 1)
                    else:
                        self.num_arrays[name] = [0] * (size + 1)
            return

        if u.startswith('FOR '):
            head, to_rest = split_for_to(stmt[4:])
            m2 = re.match(r'^([A-Z][A-Z0-9]*)\s*=\s*(.*)$', head)
            var, start_e = m2.groups()
            step = 1
            to_e = to_rest
            step_idx = find_keyword(to_rest, 'STEP')
            if step_idx != -1:
                to_e = to_rest[:step_idx].strip()
                step = eval_expr(to_rest[step_idx + 4:], self)
            start = eval_expr(start_e, self)
            limit = eval_expr(to_e, self)
            self.set_scalar(var, start)
            self.for_stack.append({
                'var': var, 'limit': limit, 'step': step,
                'body_line': self.pc, 'body_stmt': self.stmt_i,
            })
            return

        m = NEXT_RE.match(stmt)
        if m:
            if not self.for_stack:
                raise BasicError("NEXT without FOR")
            frame = self.for_stack[-1]
            cur = self.num_vars.get(frame['var'], 0) + frame['step']
            self.set_scalar(frame['var'], cur)
            done = (cur > frame['limit']) if frame['step'] > 0 else (cur < frame['limit'])
            if done:
                self.for_stack.pop()
            else:
                self.pc, self.stmt_i = frame['body_line'], frame['body_stmt']
            return

        if u.startswith('DIM'):
            return

        m = re.match(r'^INPUT\s*(?:"([^"]*)"\s*;\s*)?(.*)$', stmt, re.IGNORECASE)
        if u.startswith('INPUT') and not u.startswith('INPUT#'):
            prompt, varlist = m.groups()
            line = self.io.input(prompt or "")
            names = [v.strip() for v in varlist.split(',')]
            if len(names) == 1:
                self._assign_input(names[0], line)
            else:
                parts = line.split(',')
                for name, val in zip(names, parts):
                    self._assign_input(name.strip(), val.strip())
            return

        m = PRINT_HASH_RE.match(stmt)
        if m:
            fh, expr = m.groups()
            v = eval_expr(expr, self)
            self.open_files[int(fh)]['buffer'].append(v)
            return

        m = INPUT_HASH_RE.match(stmt)
        if m:
            fh, varname = m.groups()
            rec = self.open_files[int(fh)]['records']
            pos = self.open_files[int(fh)]['pos']
            val = rec[pos] if pos < len(rec) else 0
            self.open_files[int(fh)]['pos'] += 1
            self.set_scalar(varname.strip(), val)
            return

        if u.startswith('OPEN'):
            args = self._split_data_items(stmt[4:].strip())
            fh = int(eval_expr(args[0], self))
            mode = int(eval_expr(args[2], self)) if len(args) > 2 else 0
            self.open_files[fh] = {'mode': mode, 'buffer': [], 'records': self.io.load() if mode == 0 else [], 'pos': 0}
            return

        if u.startswith('CLOSE'):
            m2 = re.match(r'^CLOSE\s*#?\s*(\d+)?', stmt, re.IGNORECASE)
            fh = int(m2.group(1)) if m2 and m2.group(1) else 1
            f = self.open_files.pop(fh, None)
            if f and f['mode'] == 1:
                self.io.save(f['buffer'])
            return

        if u.startswith('READ'):
            names = [v.strip() for v in stmt[4:].split(',')]
            for name in names:
                val = self.data_values[self.data_ptr] if self.data_ptr < len(self.data_values) else 0
                self.data_ptr += 1
                am = re.match(r'^([A-Z][A-Z0-9]*\$?)\((.*)\)$', name)
                if am:
                    aname, idx_e = am.groups()
                    self.set_array(aname, eval_expr(idx_e, self), self._coerce(name, val))
                else:
                    self.set_scalar(name, self._coerce(name, val))
            return

        if u.startswith('PRINT'):
            self._do_print(stmt[5:])
            return

        if u.startswith('IF '):
            split = split_if_then(stmt[3:])
            if split is None:
                raise BasicError(f"IF without THEN: {stmt!r}")
            cond_e, then_part = split
            cond = eval_expr(cond_e, self)
            if truthy(cond):
                if re.match(r'^\d+$', then_part.strip()):
                    self._goto(int(then_part.strip()))
                else:
                    for s in split_statements(then_part):
                        self._exec(s)
                        if not self.running:
                            return
            return

        m = LET_RE.match(stmt)
        if m:
            name, _, idx_expr, rhs = m.groups()
            value = eval_expr(rhs, self)
            if idx_expr is not None:
                idx = eval_expr(idx_expr, self)
                self.set_array(name, idx, self._coerce(name, value))
            else:
                self.set_scalar(name, self._coerce(name, value))
            return

        raise BasicError(f"Don't know how to execute: {stmt!r}")

    def _coerce(self, name, val):
        if name.endswith('$') and not isinstance(val, str):
            return to_str(val)
        if not name.endswith('$') and isinstance(val, str):
            return val
        return val

    def _assign_input(self, name, text):
        am = re.match(r'^([A-Z][A-Z0-9]*\$?)\((.*)\)$', name)
        if am:
            aname, idx_e = am.groups()
            self.set_array(aname, eval_expr(idx_e, self), text)
        elif name.endswith('$'):
            self.set_scalar(name, text)
        else:
            try:
                self.set_scalar(name, float(text) if '.' in text else int(text))
            except ValueError:
                self.set_scalar(name, 0)

    def _do_print(self, rest):
        rest = rest.strip()
        if rest == '':
            self.io.println('')
            return
        # The listing sometimes juxtaposes TAB(n) directly against the next
        # print item with no explicit separator (e.g. TAB(0)"STRENGTH = ").
        # TAB() is a cursor-move side effect, not a value, so insert an
        # implicit ';' after it wherever one isn't already present.
        rest = re.sub(r'(TAB\([^)]*\))(?!\s*[;,]|\s*$)', r'\1;', rest, flags=re.IGNORECASE)
        # split on ; and , at top level (outside strings/parens), keep separators
        parts = []
        cur = ''
        depth = 0
        in_str = False
        for ch in rest:
            if ch == '"':
                in_str = not in_str
            if ch in '(' and not in_str:
                depth += 1
            if ch in ')' and not in_str:
                depth -= 1
            if ch in ';,' and depth == 0 and not in_str:
                parts.append(cur)
                parts.append(ch)
                cur = ''
            else:
                cur += ch
        parts.append(cur)

        trailing_no_newline = False
        for p in parts:
            p = p.strip()
            if p == ';':
                trailing_no_newline = True
                continue
            if p == ',':
                self.io.print('\t')
                trailing_no_newline = True
                continue
            if p == '':
                continue
            trailing_no_newline = False
            tm = re.match(r'^TAB\((.*)\)$', p, re.IGNORECASE)
            if tm:
                col = int(eval_expr(tm.group(1), self))
                self.io.tab(col)
                continue
            val = eval_expr(p, self)
            self.io.print(to_str(val))
        if not trailing_no_newline:
            self.io.println('')


def math_floor(x):
    import math
    return math.floor(x)
