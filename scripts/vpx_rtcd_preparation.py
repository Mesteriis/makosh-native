"""Owned portable RTCD preparation prototype; never executes upstream Perl."""

import re


def _condition(text, enabled):
    values = []
    for clause in text.split("||"):
        clause = clause.strip()
        config = re.fullmatch(r'vpx_config\("((?:CONFIG|HAVE)_[A-Z0-9_]+)"\) (eq|ne) "yes"', clause)
        if config:
            value = config[1] in enabled
            values.append(value if config[2] == "eq" else not value)
        elif clause == '$opts{arch} eq "x86_64"':
            values.append(False)
        else:
            raise ValueError("Unsupported RTCD condition: " + clause)
    return any(values)


def portable_prototypes(source, enabled):
    # These fixed upstream declarations print C forward declarations only. Our
    # generated headers use a reviewed minimal header list of their own.
    source = re.sub(
        r'sub (?:vp9_common|vpx_dsp|vpx_scale)_forward_decls\(\) \{\nprint <<EOF\n.*?\nEOF\n\}',
        '', source, flags=re.DOTALL,
    )
    stack = []  # (parent active, condition, else already seen)
    active = True
    result, symbols = [], set()
    for number, original in enumerate(source.splitlines(), 1):
        line = original.split('#', 1)[0].strip()
        if not line:
            continue
        condition = re.fullmatch(r'if \((.*)\) \{', line)
        if condition:
            value = _condition(condition[1], enabled)
            stack.append((active, value, False))
            active = active and value
            continue
        if line == '} else {':
            if not stack or stack[-1][2]:
                raise ValueError("Unexpected RTCD else")
            parent, value, _ = stack.pop()
            stack.append((parent, value, True))
            active = parent and not value
            continue
        if line == '}':
            if not stack:
                raise ValueError("Unbalanced RTCD branch")
            active = stack.pop()[0]
            continue
        proto = re.fullmatch(r'add_proto qw/([a-z0-9_ ]+) ([A-Za-z_][A-Za-z0-9_]*)/, "([^"\n]*)";', line)
        if proto is None:
            proto = re.fullmatch(r'add_proto qw/([a-z0-9_ ]+)/, "([A-Za-z_][A-Za-z0-9_]*)", "([^"\n]*)";', line)
        if proto:
            if active:
                if proto[2] in symbols:
                    raise ValueError("Duplicate RTCD symbol: " + proto[2])
                symbols.add(proto[2])
                result.append((proto[1], proto[2], proto[3]))
            continue
        if re.fullmatch(r'specialize qw/[A-Za-z0-9_ $]+/(?:, "\$[A-Za-z0-9_]+")*;', line):
            continue
        if re.fullmatch(r'forward_decls qw/(?:vp9_common|vpx_dsp|vpx_scale)_forward_decls/;', line):
            continue
        if re.fullmatch(r'(?:\$[A-Za-z0-9_]+\s*=\s*)+\x27[A-Za-z0-9_]*\x27;', line):
            continue
        if re.fullmatch(r'\$[A-Za-z0-9_]+\s*=\s*[A-Za-z0-9_]+;', line):
            continue
        if line == '1;':
            continue
        raise ValueError(f"Unsupported RTCD statement at line {number}: {line}")
    if stack:
        raise ValueError("Unclosed RTCD branch")
    return result


def portable_header(stem, prototypes):
    includes = {
        'vp9_rtcd': ['vpx/vpx_integer.h', 'vp9/common/vp9_common.h', 'vp9/common/vp9_enums.h', 'vp9/common/vp9_filter.h'],
        'vpx_dsp_rtcd': ['vpx/vpx_integer.h', 'vpx_dsp/vpx_dsp_common.h', 'vpx_dsp/vpx_filter.h'],
        'vpx_scale_rtcd': [],
    }[stem]
    guard = 'MAKOSH_' + stem.upper() + '_H'
    lines = [f'#ifndef {guard}', f'#define {guard}', '#include "vpx_config.h"', '#include <stddef.h>']
    lines.extend(f'#include "{name}"' for name in includes)
    if stem == 'vpx_scale_rtcd':
        lines.append('struct yv12_buffer_config;')
    lines += ['#ifdef __cplusplus', 'extern "C" {', '#endif', f'void {stem}(void);']
    for result, name, arguments in prototypes:
        lines += [f'{result} {name}_c({arguments});', f'#define {name} {name}_c']
    lines += ['#ifdef RTCD_C', 'static void setup_rtcd_internal(void) {}', '#endif',
              '#ifdef __cplusplus', '}', '#endif', f'#endif /* {guard} */', '']
    return '\n'.join(lines)
