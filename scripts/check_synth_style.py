#!/usr/bin/env python3
"""
check_synth_style.py — Synthesis coding-style checks for SystemVerilog.

Two checks are performed:

Check 1 — Declaration order:
  Detect signals/enum constants used before their declaration line.
  Synthesis tools (DC, Genus, Vivado in strict mode) sometimes reject forward
  references inside a module even though SV allows them.  This script flags any
  signal or enum constant whose first *use* line is earlier than its *declaration*
  line.

  Handled declaration kinds:
    - logic / wire / reg / input / output / int / ... variables
    - localparam / parameter constants
    - typedef enum { CONST, ... } type_t — both the type name and all enum constants
    - plain (non-typedef) enum { CONST, ... } type_t blocks
    - variable declarations using previously-seen typedef type names (e.g. state_t s)

Check 2 — Partial reset in always_ff:
  Detect always_ff blocks where some signals are assigned but intentionally
  omitted from the reset branch.  Partial reset is a common synthesis
  pitfall: the tool sees a mix of reset and non-reset registers in one
  always_ff and must infer two separate flip-flop enable styles.  This
  leads to Synth warnings and may produce unexpected netlist behaviour.

  A violation is reported only when at least one signal IS present in the
  reset branch (so intentional SRAM-style no-reset blocks are not flagged).
  The check handles:
    - Async active-low reset: always_ff @(posedge clk or negedge rst_n)
    - Any reset signal name matching rst*/reset* (case-insensitive)
    - begin/end block and empty-body (;) reset styles

Check 3 — Async-reset condition mixing:
  Detect always_ff blocks where the async reset condition is combined with
  other signals via logical OR/AND.  Example violation:
      always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n || flush) begin   // ← BAD: reset mixed with flush
              ...
          end
      end
  Yosys's proc_arst pass requires a pure single-signal async reset to convert
  the negedge sync to a level-sensitive reset.  Compound conditions prevent
  the conversion, leaving both edge syncs and triggering proc_dff's
  "Multiple edge sensitive events found for this signal!" error.
  Fix: split into separate conditions, e.g.
      if (!rst_n) ... else if (flush) ...

Usage:
    python3 check_synth_style.py <file1.sv> [file2.sv ...]
    Exit 0 = clean, Exit 1 = violations found.
"""

import re
import sys
import os

# ── Tokens that introduce a variable declaration ────────────────────────────
# Captures optional signing/width so we can skip them and hit the name.
DECL_KW = re.compile(
    r'\b(input|output|inout|wire|reg|logic|bit|byte|shortint|int|longint'
    r'|integer|time|real|realtime|event|tri|tri0|tri1|trireg|var)\b',
    re.ASCII
)

# Identifier pattern — plain alphanumeric + underscore, not starting with digit
IDENT = re.compile(r'\b([A-Za-z_][A-Za-z0-9_$]*)\b')

# Keywords that are NOT signal identifiers
SV_KEYWORDS = frozenset("""
    module endmodule package endpackage interface endinterface program endprogram
    class endclass function endfunction task endtask always always_ff always_comb
    always_latch initial final begin end if else case casez casex endcase for
    foreach while repeat forever do break continue return
    input output inout wire reg logic bit byte shortint int longint integer
    time real realtime event tri tri0 tri1 trireg var signed unsigned
    posedge negedge or and not buf
    assign force release deassign default parameter localparam defparam
    generate endgenerate genvar
    import export typedef enum struct union packed
    virtual automatic static protected local
    null this super new
    unique priority
    fork join join_any join_none
    wait disable fork
    property sequence assert assume cover restrict
    clocking endclocking modport
    specify endspecify timeprecision timeunit
    inside dist with
    tagged void
    string chandle
    $bits $clog2 $signed $unsigned $size $high $low $left $right
    $display $write $monitor $strobe $fopen $fclose $fwrite $fdisplay
    $finish $stop $error $warning $info $fatal
    $random $urandom $urandom_range
    $time $realtime $stime
    $rose $fell $stable $changed $past $future $sampled
    $isunknown $countones $onehot $onehot0
    $readmemh $readmemb $writememh $writememb
    FAST_MUL FAST_DIV ICACHE_EN ICACHE_SIZE ICACHE_LINE_SIZE ICACHE_WAYS
    MEM_READ_LATENCY MEM_WRITE_LATENCY MEM_DUAL_PORT
""".split())

def strip_comments_and_strings(line: str) -> str:
    """Remove // line comments and string literals from a line."""
    # Remove string literals
    line = re.sub(r'"[^"]*"', '""', line)
    # Remove // comments
    idx = line.find('//')
    if idx >= 0:
        line = line[:idx]
    return line

def prepare_for_decl_scan(line: str) -> str:
    """
    Prepare a line for declaration scanning by removing constructs that
    would cause false positives:
      - System tasks/functions like $time, $display → removed so 'time' isn't
        matched as the 'time' type keyword
      - Type casts like int'(...), logic'(...) → the type name is removed so it
        isn't treated as a declaration keyword
      - Non-blocking / relational assignment operators (<=, >=, ==, !=)
        are neutralised so we can split at '=' to get the LHS only
      - Bit literals like 1'b0, 8'hFF → removed so 'b0', 'hFF', etc. are not
        extracted as identifiers
    Returns a string suitable for extracting declared names only.
    """
    s = line
    # Strip system tasks/functions: $word
    s = re.sub(r'\$\w+', '', s)
    # Strip bit literals: <digits>'<radix_char><digits/letters>
    s = re.sub(r"\d+\s*'[shbodSHBOD][0-9xzXZa-fA-F_]*", '', s)
    # Strip type casts: word'( → remove the word so 'int'(' becomes '('
    s = re.sub(r"\b\w+\s*'(?=\s*\()", '', s)
    # Neutralise compound operators so they aren't split as '='
    s = s.replace('<=', '##').replace('>=', '##').replace('==', '##').replace('!=', '##')
    # Now split at the first bare '=' and take only the LHS; this stops
    # RHS initialiser expressions from polluting the declared-name set.
    s = s.split('=')[0]
    return s

def parse_module_ports(header_lines: list) -> set:
    """
    Extract port names AND parameter names from the ANSI module header
    (between 'module name (' and the first ');').
    These count as declared at line 0 (module header).
    """
    ports = set()
    combined = ' '.join(header_lines)
    # Extract parameter names from #(...)
    m_params = re.search(r'#\s*\((.*?)\)', combined, re.DOTALL)
    if m_params:
        param_body = m_params.group(1)
        for tok in IDENT.finditer(param_body):
            name = tok.group(1)
            if name not in SV_KEYWORDS:
                ports.add(name)
    # Strip parameter list to get port-only body
    combined_no_params = re.sub(r'#\s*\(.*?\)', '', combined, flags=re.DOTALL)
    m = re.search(r'\((.*?)\)', combined_no_params, re.DOTALL)
    if not m:
        return ports
    port_body = m.group(1)
    # Each port declaration: optional direction/type, then identifier
    for token in IDENT.finditer(port_body):
        name = token.group(1)
        if name not in SV_KEYWORDS:
            ports.add(name)
    return ports

def check_file(path: str) -> list:
    """
    Check 1: Declaration-order violations.
    Returns a list of ('decl', path, use_line, name, decl_line) tuples.
    """
    try:
        with open(path) as f:
            raw_lines = f.readlines()
    except OSError as e:
        print(f'ERROR: cannot open {path}: {e}', file=sys.stderr)
        return []

    lines = [strip_comments_and_strings(l) for l in raw_lines]
    violations = []

    # ── State machine: find module boundaries ───────────────────────────────
    i = 0
    n = len(lines)

    while i < n:
        # Look for 'module <name>' or 'package <name>'
        stripped = lines[i].strip()
        if not re.match(r'\b(module|package)\b', stripped):
            i += 1
            continue

        mod_start = i

        # Collect the header (up to the first ';')
        header_lines = []
        j = i
        while j < n:
            header_lines.append(lines[j])
            if ';' in lines[j]:
                break
            j += 1
        header_end = j + 1     # first line of module body

        # Parse port names from the header — declare at line 0
        port_names = parse_module_ports(header_lines)

        # ── Walk module body ─────────────────────────────────────────────────
        # decl_map: signal_name → first declaration line (1-based)
        decl_map: dict[str, int] = {}
        # use_map:  signal_name → first use line (1-based)
        use_map:  dict[str, int] = {}

        # Track `define / localparam names so we don't flag them
        const_names: set[str] = set()

        # Track typedef type names so variable decls using them are caught
        typedef_names: set[str] = set()

        depth = 1           # begin/end depth relative to module
        k = header_end

        while k < n:
            raw = raw_lines[k]
            clean = lines[k]
            k1 = k + 1       # 1-based line number

            # ── Track endmodule / endpackage ─────────────────────────────
            if re.search(r'\b(endmodule|endpackage)\b', clean):
                break

            # ── Detect typedef enum / enum blocks (possibly multi-line) ──
            # Covers: typedef enum [base] { CONST, ... } type_t;
            #         enum { CONST, ... } var_name;
            # All enum constant names and the typedef type name are added to
            # decl_map at the opening line so that any use BEFORE this block
            # is flagged as a declaration-order violation.
            if re.search(r'\benum\b', clean):
                enum_start_line = k1
                # Collect lines until we find the closing '}'
                enum_text = clean
                m_tmp = k + 1
                while '}' not in enum_text and m_tmp < n:
                    enum_text += ' ' + lines[m_tmp]
                    m_tmp += 1
                # Extract enum constant names from { ... }, stripping = value parts
                brace_m = re.search(r'\{([^}]*)\}', enum_text, re.DOTALL)
                if brace_m:
                    constants_body = brace_m.group(1)
                    # Remove value assignments: NAME = 3'b000 → keep NAME only
                    constants_body = re.sub(r'=[^,}]+', '', constants_body)
                    for tok in IDENT.finditer(constants_body):
                        cname = tok.group(1)
                        if (cname not in SV_KEYWORDS
                                and cname not in decl_map
                                and cname not in port_names):
                            decl_map[cname] = enum_start_line
                # If this is a typedef enum, record the type name (last ident before ';')
                if 'typedef' in enum_text:
                    after_brace = (enum_text[enum_text.rfind('}')+1:]
                                   if '}' in enum_text else '')
                    after_brace = after_brace.split(';')[0]
                    tname_matches = list(IDENT.finditer(after_brace))
                    if tname_matches:
                        tname = tname_matches[-1].group(1)
                        if tname not in SV_KEYWORDS:
                            typedef_names.add(tname)
                            if tname not in decl_map and tname not in port_names:
                                decl_map[tname] = enum_start_line

            # ── Detect variable declarations using typedef type names ─────
            # e.g. "state_t state, next_state;" or "spi_state_t state;"
            # Only fires after at least one typedef has been seen.
            if typedef_names:
                stripped_c = clean.strip()
                first_m = re.match(r'([A-Za-z_][A-Za-z0-9_$]*)\s', stripped_c)
                if (first_m and first_m.group(1) in typedef_names):
                    rest = stripped_c[first_m.end():]
                    rest = rest.split(';')[0]        # before ';'
                    # Ignore if looks like a module instantiation or function call
                    if '(' not in rest:
                        rest = rest.split('=')[0]    # LHS only
                        rest = re.sub(r'\[.*?\]', '', rest)  # strip array dims
                        for tok in IDENT.finditer(rest):
                            vname = tok.group(1)
                            if (vname not in SV_KEYWORDS
                                    and vname not in decl_map
                                    and vname not in port_names):
                                decl_map[vname] = k1

            # ── Detect declarations ──────────────────────────────────────
            if DECL_KW.search(clean):
                # Use the sanitised LHS-only string to extract declared names.
                # This avoids false positives from:
                #   - type casts like int'(expr)
                #   - bit literals like 1'b0 → 'b0' identifier
                #   - RHS initialiser expressions (wire foo = expr)
                decl_scan_str = prepare_for_decl_scan(clean)
                # Strip array dimensions to avoid false positives from ranges
                decl_scan_str = re.sub(r'\[.*?\]', '', decl_scan_str)
                in_decl = False
                for tok in IDENT.finditer(decl_scan_str):
                    name = tok.group(1)
                    if name in SV_KEYWORDS:
                        if DECL_KW.match(name):
                            in_decl = True
                        continue
                    if in_decl:
                        if name not in decl_map and name not in port_names:
                            decl_map[name] = k1
                        # Allow multiple names on the same decl line
                        # (in_decl stays True until ';')
                if ';' in clean:
                    pass     # in_decl naturally resets per-line

            # ── Detect localparam / parameter names ─────────────────────
            if re.search(r'\b(localparam|parameter)\b', clean):
                # Use the sanitised LHS-only string to avoid RHS false positives
                const_scan_str = prepare_for_decl_scan(clean)
                const_scan_str = re.sub(r'\[.*?\]', '', const_scan_str)
                for tok in IDENT.finditer(const_scan_str):
                    name = tok.group(1)
                    if name not in SV_KEYWORDS:
                        const_names.add(name)
                        if name not in decl_map:
                            decl_map[name] = k1  # treat as declared here

            # ── Detect `define macro names ──────────────────────────────
            m_def = re.match(r'\s*`define\s+(\w+)', raw_lines[k])
            if m_def:
                const_names.add(m_def.group(1))

            # ── Record uses ──────────────────────────────────────────────
            # Strip system tasks/functions before scanning to avoid false
            # positives like 'time' extracted from '$time'.
            clean_for_uses = re.sub(r'\$\w+', '', clean)
            for tok in IDENT.finditer(clean_for_uses):
                name = tok.group(1)
                if name in SV_KEYWORDS:
                    continue
                if name in port_names:
                    continue
                if name not in use_map:
                    use_map[name] = k1

            k += 1

        # ── Compare first-use vs declaration ────────────────────────────────
        for name, use_line in use_map.items():
            if name not in decl_map:
                continue     # not a locally declared signal
            decl_line = decl_map[name]
            if use_line < decl_line:
                violations.append(('decl', path, use_line, name, decl_line))

        i = header_end

    return violations

# =============================================================================
# Check 2 — Partial reset in always_ff
# =============================================================================

def _events_in_order(line: str):
    """
    Yield ('begin'|'end', position) for each SV begin/end keyword in text
    order.  Uses word boundaries so endcase/endmodule/etc. are not matched.
    """
    events = [(m.group(1), m.start())
              for m in re.finditer(r'\b(begin|end)\b', line)]
    events.sort(key=lambda x: x[1])
    return events

def _extract_rst_sig(sens_text: str):
    """
    Return the reset signal name from a sensitivity-list string, or None.
    Looks for posedge/negedge entries that are not the clock.
    e.g.  "posedge clk or negedge rst_n" → "rst_n"
    """
    for m in re.finditer(r'(?:posedge|negedge)\s+([A-Za-z_]\w*)', sens_text):
        sig = m.group(1)
        if not re.match(r'clk', sig, re.IGNORECASE):
            return sig
    return None

def _nb_lhs_iter(line: str):
    """
    Yield non-blocking assignment LHS signal names from a line.

    Only matches ``<=`` that appear at parentheses depth zero, which
    distinguishes non-blocking assignments (statement level) from
    relational ``<=`` comparisons used inside if/while/for conditions
    or expression sub-expressions.

    e.g. on:  ``if (a <= b) c <= d;``
                 ``^^^^^^^^``  skipped (depth 1 inside the '(...)')
                             ``^^^^^^``  yielded → 'c'
    """
    depth = 0
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '(':
            depth += 1
            i += 1
        elif c == ')':
            if depth > 0:
                depth -= 1
            i += 1
        elif line[i:i+2] == '<=' and depth == 0:
            # Extract the LHS sitting immediately before this '<='
            lhs_text = line[:i].rstrip()
            m = re.search(r'\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*$', lhs_text)
            if m:
                sig = m.group(1)
                if sig not in SV_KEYWORDS:
                    yield sig
            i += 2
        else:
            i += 1

def check_ff_partial_reset(path: str) -> list:
    """
    Check 2: Partial-reset style in always_ff.

    For each always_ff block that has a reset branch (if (!rst_n) begin ...):
      - Collect every NB-assignment LHS in the entire block  → all_written
      - Collect every NB-assignment LHS in the reset branch  → reset_written
      - Report (all_written − reset_written) when reset_written is non-empty.

    Returns a list of ('reset', path, ff_line_1based, signal) tuples.

    Algorithm:
      Uses event-ordered depth tracking: on each line, 'end' tokens are
      processed before 'begin' tokens in text order.  This correctly handles
      ``end else begin`` style lines where the 'end' closes the reset branch
      before the 'begin' opens the else branch.

    Limitations:
      - Handles begin/end and empty-body (;) reset styles only.
      - Always-ff blocks without any reset signal in the sensitivity list
        are silently skipped (synchronous-reset blocks flagged only when
        the condition identifer matches rst*/reset*).
    """
    try:
        with open(path) as f:
            raw_lines = f.readlines()
    except OSError as e:
        print(f'ERROR: cannot open {path}: {e}', file=sys.stderr)
        return []

    clean_lines = [strip_comments_and_strings(l) for l in raw_lines]
    n = len(clean_lines)
    violations = []

    i = 0
    while i < n:
        cl_i = clean_lines[i]
        if not re.search(r'\balways_ff\b', cl_i):
            i += 1
            continue

        ff_line = i + 1  # 1-based for reporting

        # ── Extract async reset signal from sensitivity list ──────────────
        sens = cl_i
        j = i
        while ')' not in sens and j + 1 < n:
            j += 1
            sens += ' ' + clean_lines[j]
        rst_sig = _extract_rst_sig(sens)

        # ── Collect the always_ff block (everything up to the matching end) ─
        # Scan forward to the first 'begin'.
        k = j
        while k < n and 'begin' not in clean_lines[k]:
            k += 1
        if k >= n:
            i = j + 1
            continue

        block = []          # list of (0-based line index, clean_line)
        depth = 0
        while k < n:
            cl_k = clean_lines[k]
            block.append((k, cl_k))
            for ev_type, _ in _events_in_order(cl_k):
                depth += 1 if ev_type == 'begin' else -1
            if depth <= 0:
                break
            k += 1
        next_i = k + 1

        # ── Analyse the block ─────────────────────────────────────────────
        all_written   = set()
        reset_written = set()

        bd              = 0       # current begin/end depth (0 = before any begin)
        block_entered   = False   # True after first 'begin' seen
        in_reset        = False
        reset_entry_dep = None    # depth level INSIDE the reset if-block

        for blk_idx, (li, cl) in enumerate(block):
            # ── Detect reset 'if' at depth 1, before updating depth ────────
            if block_entered and bd == 1 and not in_reset:
                if re.search(r'\bif\b', cl):
                    cond_m = re.search(r'\bif\s*\(([^)]*)\)', cl)
                    if cond_m:
                        cond = cond_m.group(1)
                        is_rst = (
                            (rst_sig and
                             re.search(r'\b' + re.escape(rst_sig) + r'\b', cond))
                            or bool(re.search(r'\brst\w*\b|\breset\w*\b',
                                              cond, re.IGNORECASE))
                        )
                        if is_rst:
                            # Check for empty body: if (!rst_n) ;
                            after_cond = cl[cond_m.end():]
                            if re.match(r'\s*;', after_cond):
                                pass   # intentional empty reset — skip
                            else:
                                in_reset = True
                                # reset_entry_dep = depth INSIDE the if block.
                                # Whether 'begin' is on this line or the next,
                                # the inside depth will be bd + 1 = 2.
                                reset_entry_dep = bd + 1

            # ── Collect NB assignment LHS ─────────────────────────────────
            for sig in _nb_lhs_iter(cl):
                all_written.add(sig)
                if in_reset:
                    reset_written.add(sig)

            # ── Update depth using event-ordered tracking ─────────────────
            for ev_type, _ in _events_in_order(cl):
                if ev_type == 'begin':
                    bd += 1
                    block_entered = True
                else:  # 'end'
                    # Exit reset branch when depth drops back to entry level.
                    # Using '<=' so that depth == reset_entry_dep − 1 after
                    # this 'end' correctly triggers the exit.
                    if in_reset and reset_entry_dep is not None:
                        if bd <= reset_entry_dep:
                            in_reset = False
                            reset_entry_dep = None
                    bd -= 1

        # ── Report partial-reset signals ──────────────────────────────────
        # Only flag when SOME signals are intentionally reset (reset_written
        # is non-empty), so pure SRAM-style no-reset blocks are silently
        # accepted.
        partial = all_written - reset_written
        if reset_written and partial:
            for sig in sorted(partial):
                violations.append(('reset', path, ff_line, sig))

        i = next_i

    return violations

# =============================================================================
# Check 3 — Async-reset condition mixing
# =============================================================================

def check_ff_async_reset_mix(path: str) -> list:
    """
    Check 3: Async reset condition must not be mixed with other signals.

    For each always_ff block with an async reset in its sensitivity list
    (e.g. ``negedge rst_n``), check the first 'if' condition at depth 1.
    If the condition references the reset signal AND contains a logical
    operator (||, &&), report a violation.

    Returns a list of ('async-mix', path, ff_line_1based, cond_text) tuples.
    """
    try:
        with open(path) as f:
            raw_lines = f.readlines()
    except OSError as e:
        print(f'ERROR: cannot open {path}: {e}', file=sys.stderr)
        return []

    clean_lines = [strip_comments_and_strings(l) for l in raw_lines]
    n = len(clean_lines)
    violations = []

    i = 0
    while i < n:
        cl_i = clean_lines[i]
        if not re.search(r'\balways_ff\b', cl_i):
            i += 1
            continue

        ff_line = i + 1

        # Extract sensitivity list (may span multiple lines)
        sens = cl_i
        j = i
        while ')' not in sens and j + 1 < n:
            j += 1
            sens += ' ' + clean_lines[j]
        rst_sig = _extract_rst_sig(sens)

        # Only check blocks with an async reset in the sensitivity list
        if not rst_sig:
            i = j + 1
            continue

        # Scan forward for the first 'if' after the first 'begin'
        k = j
        while k < n and 'begin' not in clean_lines[k]:
            k += 1
        if k >= n:
            i = j + 1
            continue

        # Look for the first 'if (...)' on the next non-empty lines.
        # The condition may span multiple lines; collect until parens balance.
        m_pos = k + 1
        # Also allow the 'if' on the same line as 'begin'
        scan_start = k
        found_if = False
        for s in range(scan_start, min(scan_start + 20, n)):
            line_s = clean_lines[s]
            if_m = re.search(r'\bif\s*\(', line_s)
            if if_m:
                # Collect the full condition (paren-balanced)
                cond_text = line_s[if_m.end()-1:]  # starts with '('
                depth = 0
                cond_acc = ''
                done = False
                t = s
                idx_in_line = if_m.end() - 1
                while t < n and not done:
                    src = clean_lines[t][idx_in_line:] if t == s else clean_lines[t]
                    for ch in src:
                        cond_acc += ch
                        if ch == '(':
                            depth += 1
                        elif ch == ')':
                            depth -= 1
                            if depth == 0:
                                done = True
                                break
                    if not done:
                        t += 1
                        idx_in_line = 0
                # cond_acc is like "(!rst_n || flush)"
                inner = cond_acc.strip()
                if inner.startswith('(') and inner.endswith(')'):
                    inner = inner[1:-1].strip()
                # Check if reset signal is referenced
                refs_rst = bool(re.search(r'\b' + re.escape(rst_sig) + r'\b',
                                          inner))
                if refs_rst:
                    # Check for logical operators (mixing)
                    if re.search(r'\|\||&&', inner):
                        violations.append(('async-mix', path, s + 1, inner))
                found_if = True
                break

        i = j + 1 if not found_if else (s + 1)

    return violations

def main():
    import argparse
    ap = argparse.ArgumentParser(
        description='Synthesis coding-style checks for SystemVerilog.\n'
                    '  Check 1: signal declaration order\n'
                    '  Check 2: partial reset in always_ff blocks\n'
                    '  Check 3: async-reset condition mixing')
    ap.add_argument('files', nargs='+', help='SystemVerilog source files to check')
    ap.add_argument('--quiet', '-q', action='store_true',
                    help='Only print violations, not per-file OK messages')
    ap.add_argument('--no-decl', action='store_true',
                    help='Skip declaration-order check (Check 1)')
    ap.add_argument('--no-reset', action='store_true',
                    help='Skip partial-reset check (Check 2)')
    ap.add_argument('--no-async-mix', action='store_true',
                    help='Skip async-reset condition mixing check (Check 3)')
    args = ap.parse_args()

    total_violations = 0

    for path in args.files:
        file_viols = []

        if not args.no_decl:
            file_viols += check_file(path)

        if not args.no_reset:
            file_viols += check_ff_partial_reset(path)

        if not args.no_async_mix:
            file_viols += check_ff_async_reset_mix(path)

        if file_viols:
            for v in sorted(file_viols, key=lambda x: x[2]):
                if v[0] == 'decl':
                    _, f, use_ln, name, decl_ln = v
                    print(f'{f}:{use_ln}: [decl-order] \'{name}\' used before '
                          f'declaration (declared at line {decl_ln})')
                elif v[0] == 'reset':
                    _, f, ff_ln, name = v
                    print(f'{f}:{ff_ln}: [partial-reset] \'{name}\' assigned in '
                          f'always_ff but missing from reset branch')
                else:  # 'async-mix'
                    _, f, if_ln, cond = v
                    print(f'{f}:{if_ln}: [async-reset-mix] async reset condition '
                          f'mixed with other signals: \'if ({cond})\' — split '
                          f'into separate if/else-if conditions')
            total_violations += len(file_viols)
        elif not args.quiet:
            print(f'OK: {os.path.basename(path)}')

    if total_violations:
        print(f'\n{total_violations} violation(s) found.')
        sys.exit(1)
    elif not args.quiet:
        print('\nAll files clean.')
    sys.exit(0)

if __name__ == '__main__':
    main()
