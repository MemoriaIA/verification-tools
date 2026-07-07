#!/usr/bin/env bash
# Verifies the CI gate path proves real execution rather than YAML presence.

set -u

WORKFLOW="${1:-}"
if [ -z "$WORKFLOW" ] || [ ! -f "$WORKFLOW" ]; then
  echo "G-19 FAIL: structural checker requires workflow file argument"
  exit 1
fi

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="$(command -v python)"
else
  echo "G-19 FAIL: structural checker requires python3 or python on PATH"
  exit 1
fi

"$PYTHON_BIN" - "$WORKFLOW" <<'PY'
import hashlib
import re
import sys

path = sys.argv[1]
workflow_path = path.replace("\\", "/")
strict_workflow_proof = workflow_path.endswith(".github/workflows/ci.yml")
with open(path, "r", encoding="utf-8") as handle:
    lines = handle.read().splitlines()

errors = []


def fail(message):
    errors.append(message)


for line_number, line in enumerate(lines, start=1):
    if "\t" in line:
        fail(f"tab character found at line {line_number}")


def indent_of(line):
    stripped = line.lstrip(" ")
    if not stripped:
        return -1
    return len(line) - len(stripped)


KEY_RE = re.compile(r'^(\s*)(?:"([^"]+)"|\'([^\']+)\'|(<<)|([A-Za-z0-9_-]+))\s*:\s*(.*)$')
STEP_ITEM_RE = re.compile(r'^(\s*)-\s*(?:(?:"([^"]+)"|\'([^\']+)\'|([A-Za-z0-9_-]+))\s*:\s*(.*))?\s*$')
BLOCK_SCALAR_INDICATOR_RE = re.compile(r'^[|>](?:[-+]?|[1-9][-+]?|[-+][1-9])$')


def decode_double_quoted_scalar(value):
    def replace_unicode(match):
        return chr(int(match.group(1), 16))

    value = re.sub(r'\\x([0-9A-Fa-f]{2})', replace_unicode, value)
    value = re.sub(r'\\u([0-9A-Fa-f]{4})', replace_unicode, value)
    value = re.sub(r'\\U([0-9A-Fa-f]{8})', replace_unicode, value)
    replacements = {
        r'\"': '"',
        r'\\': '\\',
        r'\/': '/',
        r'\b': '\b',
        r'\f': '\f',
        r'\n': '\n',
        r'\r': '\r',
        r'\t': '\t',
    }
    for escaped, replacement in replacements.items():
        value = value.replace(escaped, replacement)
    return value


def decode_double_quoted_key(value):
    return decode_double_quoted_scalar(value)


def normalize_key(double_quoted, single_quoted, bare):
    if double_quoted is not None:
        return decode_double_quoted_key(double_quoted)
    if single_quoted is not None:
        return single_quoted.replace("''", "'")
    return bare


def parse_key(line):
    match = KEY_RE.match(line)
    if not match:
        return None
    key = match.group(4) or normalize_key(match.group(2), match.group(3), match.group(5))
    value = match.group(6).strip()
    return {
        "indent": len(match.group(1)),
        "key": key,
        "value": value,
    }


def scalar_value(value):
    bare = value.split("#", 1)[0].strip()
    return BLOCK_SCALAR_INDICATOR_RE.match(bare) is not None


def invalid_block_scalar_indicator(value):
    bare = value.split("#", 1)[0].strip()
    return bare.startswith(("|", ">")) and BLOCK_SCALAR_INDICATOR_RE.match(bare) is None


def scalar_style(value):
    bare = value.split("#", 1)[0].strip()
    if bare.startswith("|"):
        return "|"
    if bare.startswith(">"):
        return ">"
    return ""


def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def bare_value(value):
    return value.split("#", 1)[0].strip()


def reject_inline_map_value(context, value):
    bare = bare_value(value)
    if not bare:
        return False
    if bare.startswith("*"):
        fail(f"{context} must not be a YAML alias")
    elif bare.startswith("{") or bare.startswith("["):
        fail(f"{context} must not use flow-style YAML")
    else:
        fail(f"{context} must be a block map")
    return True


def reject_merge_keys(start, end, parent_indent, context):
    for index in range(start + 1, end):
        if SCALAR_LINES[index]:
            continue
        parsed = parse_key(lines[index])
        if parsed and parsed["indent"] > parent_indent and parsed["key"] == "<<":
            fail(f"{context} must not use YAML merge keys")


def block_end(start, parent_indent, scalar_lines):
    index = start + 1
    while index < len(lines):
        if lines[index].strip() and not scalar_lines[index] and indent_of(lines[index]) <= parent_indent:
            break
        index += 1
    return index


def scalar_line_mask():
    mask = [False] * len(lines)
    active_indent = None
    for index, line in enumerate(lines):
        if active_indent is not None:
            if not line.strip() or indent_of(line) > active_indent:
                mask[index] = True
                continue
            active_indent = None
        parsed = parse_key(line)
        if parsed and invalid_block_scalar_indicator(parsed["value"]):
            fail(f"invalid YAML block scalar indicator at line {index + 1}")
        if parsed and scalar_value(parsed["value"]):
            active_indent = parsed["indent"]
            continue
        item = STEP_ITEM_RE.match(line)
        if item and invalid_block_scalar_indicator((item.group(5) or "").strip()):
            fail(f"invalid YAML block scalar indicator at line {index + 1}")
        if item and scalar_value((item.group(5) or "").strip()):
            active_indent = len(item.group(1)) + 2
    return mask


SCALAR_LINES = scalar_line_mask()


def line_has_jobs_text(line):
    if not line.strip() or line.lstrip().startswith("#"):
        return False
    return re.search(r'(^|[^A-Za-z0-9_-])jobs\s*:', line) is not None


top_jobs = [
    index for index, line in enumerate(lines)
    if not SCALAR_LINES[index]
    and (parsed := parse_key(line))
    and parsed["indent"] == 0
    and parsed["key"] == "jobs"
]

top_defaults = [
    index for index, line in enumerate(lines)
    if not SCALAR_LINES[index]
    and (parsed := parse_key(line))
    and parsed["indent"] == 0
    and parsed["key"] == "defaults"
]

top_env = [
    index for index, line in enumerate(lines)
    if not SCALAR_LINES[index]
    and (parsed := parse_key(line))
    and parsed["indent"] == 0
    and parsed["key"] == "env"
]

for index, line in enumerate(lines):
    if SCALAR_LINES[index]:
        continue
    parsed = parse_key(line)
    if parsed and parsed["key"] == "workflow_dispatch":
        fail("workflow_dispatch must not be enabled for the required G-19 proof workflow")
    if parsed and parsed["key"] == "on":
        on_value = strip_quotes(parsed["value"])
        if re.search(r"(^|[,\[\s])workflow_dispatch([,\]\s]|$)", on_value):
            fail("workflow_dispatch must not be enabled for the required G-19 proof workflow")

if len(top_jobs) != 1:
    fail(f"expected exactly one top-level jobs: key, found {len(top_jobs)}")
    top_jobs_index = None
else:
    top_jobs_index = top_jobs[0]
    for index, line in enumerate(lines[:top_jobs_index]):
        if line_has_jobs_text(line):
            fail("jobs: text appears before the real top-level workflow jobs map")
            break


GATE_STEP_NAME = "Run verification gate suite"
SENTINEL_STEP_NAME = "G-19 CI anti-theater (run-gates execution proof required)"


def find_direct_child(start, end, parent_indent, key_name):
    found = []
    for index in range(start + 1, end):
        if SCALAR_LINES[index]:
            continue
        parsed = parse_key(lines[index])
        if parsed and parsed["indent"] == parent_indent + 2 and parsed["key"] == key_name:
            found.append(index)
    return found


def collect_direct_controls(start, end, parent_indent):
    controls = []
    for index in range(start + 1, end):
        if SCALAR_LINES[index]:
            continue
        parsed = parse_key(lines[index])
        if parsed and parsed["indent"] == parent_indent + 2:
            controls.append((index, parsed["key"], parsed["value"]))
    return controls


def collect_run_lines(run_index, run_indent):
    collected = []
    index = run_index + 1
    while index < len(lines):
        if lines[index].strip() and not SCALAR_LINES[index] and indent_of(lines[index]) <= run_indent:
            break
        if SCALAR_LINES[index]:
            text = lines[index]
            cut = min(len(text), run_indent + 2)
            collected.append(text[cut:] if len(text) >= cut else "")
        index += 1
    return collected


def unescaped_quote_count(value):
    count = 0
    escaped = False
    for char in value:
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == '"':
            count += 1
    return count


def single_quote_count(value):
    count = 0
    index = 0
    while index < len(value):
        if value[index] != "'":
            index += 1
            continue
        if index + 1 < len(value) and value[index + 1] == "'":
            index += 2
            continue
        count += 1
        index += 1
    return count


def quoted_content(value, quote):
    start = value.find(quote)
    if start < 0:
        return value
    escaped = False
    for index in range(start + 1, len(value)):
        char = value[index]
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote == '"':
            escaped = True
            continue
        if char == quote:
            return value[start + 1:index]
    return value[start + 1:]


def single_quoted_content(value):
    start = value.find("'")
    if start < 0:
        return value
    result = []
    index = start + 1
    while index < len(value):
        char = value[index]
        if char == "'":
            if index + 1 < len(value) and value[index + 1] == "'":
                result.append("'")
                index += 2
                continue
            return "".join(result)
        result.append(char)
        index += 1
    return "".join(result)


def collect_inline_run_lines(run_index, run_indent, value):
    raw = value.strip()
    if not raw:
        return []
    def continuation_parts(stop_when_closed=None):
        parts = []
        index = run_index + 1
        while index < len(lines):
            if lines[index].strip() and not SCALAR_LINES[index] and indent_of(lines[index]) <= run_indent:
                break
            cut = min(len(lines[index]), run_indent + 2)
            parts.append(lines[index][cut:] if len(lines[index]) >= cut else "")
            if stop_when_closed is not None and stop_when_closed(" ".join([raw] + parts)):
                break
            index += 1
        return parts
    if raw.startswith('"'):
        parts = [raw]
        if unescaped_quote_count(raw) < 2:
            parts.extend(continuation_parts(lambda text: unescaped_quote_count(text) >= 2))
        return [decode_double_quoted_scalar(quoted_content(" ".join(part.strip() for part in parts), '"'))]
    if raw.startswith("'"):
        parts = [raw]
        if single_quote_count(raw) < 2:
            parts.extend(continuation_parts(lambda text: single_quote_count(text) >= 2))
        return [single_quoted_content(" ".join(part.strip() for part in parts))]
    parts = [raw] + continuation_parts()
    return [strip_quotes(" ".join(part.strip() for part in parts))]


def parse_steps(steps_index, steps_end):
    steps = []
    index = steps_index + 1
    while index < steps_end:
        if SCALAR_LINES[index]:
            index += 1
            continue
        stripped = lines[index].strip()
        if re.match(r'^-\s*<<\s*:', stripped):
            fail("jobs.gates.steps must not use YAML merge keys")
            index += 1
            continue
        item = parse_step_item(lines[index])
        if not item or item["indent"] != 6:
            if re.match(r'^-\s*[&*]', stripped):
                fail("jobs.gates.steps must not use YAML anchors or aliases")
            elif re.match(r'^-\s*(?:&[A-Za-z0-9_-]+\s+)?[\{\[]', stripped):
                fail("jobs.gates.steps must not use flow-style step items")
            index += 1
            continue
        step = {
            "name": f"anonymous step at line {index + 1}",
            "start": index,
            "end": None,
            "keys": {},
            "key_indexes": {},
            "key_counts": {},
            "run_style": "",
            "run_lines": [],
        }
        if item["key"]:
            record_step_key(step, item["key"], item["value"], index, 8)
        cursor = index + 1
        while cursor < steps_end:
            if lines[cursor].strip() and not SCALAR_LINES[cursor]:
                current_indent = indent_of(lines[cursor])
                if current_indent <= 6:
                    break
                parsed = parse_key(lines[cursor])
                if parsed and parsed["indent"] == 8:
                    key = parsed["key"]
                    record_step_key(step, key, parsed["value"], cursor, parsed["indent"])
            cursor += 1
        step["end"] = cursor
        steps.append(step)
        index = cursor
    return steps


def parse_step_item(line):
    match = STEP_ITEM_RE.match(line)
    if not match:
        return None
    key = normalize_key(match.group(2), match.group(3), match.group(4)) if any(match.group(i) is not None for i in (2, 3, 4)) else ""
    return {
        "indent": len(match.group(1)),
        "key": key,
        "value": (match.group(5) or "").strip(),
    }


def record_step_key(step, key, value, index, effective_indent):
    if key == "<<":
        fail("jobs.gates.steps must not use YAML merge keys")
        return
    if key == "name":
        step["name"] = strip_quotes(value)
    else:
        step["keys"][key] = value
        step["key_indexes"].setdefault(key, []).append(index)
        step["key_counts"][key] = step["key_counts"].get(key, 0) + 1
        if key == "run":
            if re.match(r'^[&*]', value.strip()):
                fail("jobs.gates run values must not use YAML anchors or aliases")
            step["run_style"] = scalar_style(value)
            if scalar_value(value):
                step["run_lines"] = collect_run_lines(index, effective_indent)
            elif value:
                step["run_lines"] = collect_inline_run_lines(index, effective_indent, value)
            else:
                step["run_lines"] = []


def executable_lines(run_lines):
    result = []
    for line in run_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        result.append(stripped)
    return result


def exec_digest(exec_lines):
    return hashlib.sha256("\n".join(exec_lines).encode("utf-8")).hexdigest()


def contains_neutralizer(text):
    return re.search(r'(^|\s)set\s+\+e(\s|$)|\|\|\s*(true|:)(\s|\)|;|$)|;\s*(true|exit\s+0)(\s|\)|;|$)', text) is not None


if len(top_defaults) > 1:
    fail(f"expected at most one top-level defaults: key, found {len(top_defaults)}")

for defaults_index in top_defaults:
    defaults_value = parse_key(lines[defaults_index])["value"]
    if reject_inline_map_value("top-level defaults", defaults_value):
        continue
    defaults_end = block_end(defaults_index, 0, SCALAR_LINES)
    reject_merge_keys(defaults_index, defaults_end, 0, "top-level defaults")
    run_indexes = find_direct_child(defaults_index, defaults_end, 0, "run")
    for run_index in run_indexes:
        run_value = parse_key(lines[run_index])["value"]
        if reject_inline_map_value("top-level defaults.run", run_value):
            continue
        run_end = block_end(run_index, 2, SCALAR_LINES)
        reject_merge_keys(run_index, run_end, 2, "top-level defaults.run")
        shell_indexes = find_direct_child(run_index, run_end, 2, "shell")
        workdir_indexes = find_direct_child(run_index, run_end, 2, "working-directory")
        if workdir_indexes:
            fail("top-level defaults.run must not define working-directory")
        for shell_index in shell_indexes:
            parsed = parse_key(lines[shell_index])
            value = strip_quotes(parsed["value"])
            if value != "bash":
                fail("top-level defaults.run.shell must be exactly bash")
            if contains_neutralizer(value):
                fail("top-level defaults.run.shell contains a neutralizer")


def contains_function_definition(exec_lines):
    for index, line in enumerate(exec_lines):
        if re.match(r'^(function\s+)?[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{', line):
            return True
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*$', line):
            cursor = index + 1
            while cursor < len(exec_lines) and not exec_lines[cursor].strip():
                cursor += 1
            if cursor < len(exec_lines) and re.match(r'^\{\s*$', exec_lines[cursor]):
                return True
        if re.match(r'^function\s+[A-Za-z_][A-Za-z0-9_]*', line):
            return True
    return False


def contains_unsupported_sentinel_control(exec_lines):
    for line in exec_lines:
        code = line.split("#", 1)[0].strip()
        if re.search(r'(\|\||&&)\s*\{', code):
            return True
        if re.match(r'^[{}]\s*$', code):
            return True
        if re.match(r'^(while|until|for|select|case)\b', code):
            return True
        if re.match(r'^(do|done|esac)\b', code):
            return True
        if code == ";;":
            return True
    return False


PROOF_ASSIGNMENT_PATTERN = re.compile(r'^PROOF="\$\{\{\s*steps\.run_gates\.outputs\.vt_g19_exec_proof\s*\}\}"$')


def normalize_shell_escapes(code):
    return re.sub(r'\\([A-Za-z0-9_./:=@%+\-])', r'\1', code)


def decode_ansi_c_escape_payload(value):
    def replace_hex(match):
        return chr(int(match.group(1), 16))

    def replace_octal(match):
        return chr(int(match.group(1), 8))

    value = re.sub(r'\\([0-7]{1,3})', replace_octal, value)
    value = re.sub(r'\\x([0-9A-Fa-f]{2})', replace_hex, value)
    value = re.sub(r'\\u([0-9A-Fa-f]{4})', replace_hex, value)
    value = re.sub(r'\\U([0-9A-Fa-f]{8})', replace_hex, value)
    replacements = {
        r'\a': '\a',
        r'\b': '\b',
        r'\e': '\x1b',
        r'\E': '\x1b',
        r'\f': '\f',
        r'\n': '\n',
        r'\r': '\r',
        r'\t': '\t',
        r'\v': '\v',
        r'\\': '\\',
        r"\'": "'",
        r'\"': '"',
    }
    for escaped, replacement in replacements.items():
        value = value.replace(escaped, replacement)
    return value


def decode_ansi_c_quotes(code):
    return re.sub(
        r"\$'((?:\\.|[^'])*)'",
        lambda match: decode_ansi_c_escape_payload(match.group(1)),
        code,
    )


def normalize_shell_words(code):
    normalized = decode_ansi_c_quotes(code)
    normalized = normalize_shell_escapes(normalized)
    normalized = re.sub(r'\$"([^"]*)"', r"\1", normalized)
    normalized = normalized.replace("'", "").replace('"', "")
    return normalized


def proof_mutation_lines(exec_lines):
    mutations = []
    for line in exec_lines:
        code = line.split("#", 1)[0].strip()
        if not code or PROOF_ASSIGNMENT_PATTERN.match(code):
            continue
        normalized = normalize_shell_words(code)
        if re.search(r'(^|[;&|]\s*)(?:(?:builtin|command)\s+)*(declare|local|typeset)\b[^#;&|]*\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[^#;&|]*\bPROOF\b', normalized):
            mutations.append(line)
            continue
        if re.search(r'(^|[;&|]\s*)(?:(?:builtin|command)\s+)*(declare|local|typeset)\b', normalized) and re.search(r'(^|[\s;])-\$\{?[A-Za-z_][A-Za-z0-9_]*\}?', normalized):
            mutations.append(line)
            continue
        if re.search(r'(^|[;&|]\s*)(?:(?:builtin|command)\s+)*(declare|local|typeset)\b[^#;&|]*(^|[\s;])-[-A-Za-z]*n[-A-Za-z]*(\s|$)', normalized):
            mutations.append(line)
            continue
        if re.search(r'\$\{PROOF(?::[-=]|=)', normalized):
            mutations.append(line)
            continue
        if re.match(r'^(declare|local|typeset)\b', normalized) and re.search(r'(^|[\s;])-[-A-Za-z]*n[-A-Za-z]*(\s|$)', normalized):
            mutations.append(line)
            continue
        if re.match(r'^PROOF(\+)?=', normalized) or re.match(r'^PROOF\[[^]]+\](\+)?=', normalized):
            mutations.append(line)
            continue
        if re.match(r'^(declare|local|typeset|export|readonly)\b.*(^|[\s;])PROOF(\b|=)', normalized):
            mutations.append(line)
            continue
        if re.match(r'^unset\b.*(^|[\s;])PROOF\b', normalized):
            mutations.append(line)
            continue
        if re.search(r'\b(read|printf\s+-v|eval)\b.*\bPROOF\b', normalized):
            mutations.append(line)
    return mutations


def shell_depths(exec_lines):
    depths = []
    depth = 0
    for line in exec_lines:
        stripped = line.strip()
        depths.append(depth)
        if re.match(r'^if\b.*\bthen\s*$', stripped):
            depth += 1
        elif re.match(r'^fi\s*$', stripped):
            depth = max(0, depth - 1)
    return depths


def require_top_level_branch(exec_lines, pattern, label):
    depths = shell_depths(exec_lines)
    for index, line in enumerate(exec_lines):
        if depths[index] == 0 and pattern.match(line):
            if branch_exits_before_else_or_fi(exec_lines, index):
                return True
            fail(f"{label} failure branch must terminate with literal exit 1 before else or fi")
            return False
    fail(f"sentinel does not assert {label}")
    return False


def branch_exits_before_else_or_fi(exec_lines, start_index):
    depth = 1
    for line in exec_lines[start_index + 1:]:
        stripped = line.strip()
        if depth == 1 and re.match(r'^(else|elif)\b', stripped):
            return False
        if depth == 1 and stripped == "exit 1":
            return True
        if re.match(r'^if\b.*\bthen\s*$', stripped):
            depth += 1
        elif re.match(r'^fi\s*$', stripped):
            depth -= 1
            if depth == 0:
                return False
    return False


FORBIDDEN_ENV_KEYS = {
    "BASH_ENV",
    "GITHUB_ENV",
    "GITHUB_PATH",
    "PATH",
    "PYTHON",
    "PYTHON_PATH",
    "PYTHONPATH",
}


def inspect_env_block(env_index, env_indent, context):
    parsed_env = parse_key(lines[env_index])
    if parsed_env:
        env_value = parsed_env["value"]
    else:
        item = parse_step_item(lines[env_index])
        if not item or item["key"] != "env":
            fail(f"{context}.env is not a parseable block")
            return
        env_value = item["value"]
    if reject_inline_map_value(f"{context}.env", env_value):
        return
    env_end = block_end(env_index, env_indent, SCALAR_LINES)
    reject_merge_keys(env_index, env_end, env_indent, f"{context}.env")
    for index in range(env_index + 1, env_end):
        if SCALAR_LINES[index]:
            continue
        parsed = parse_key(lines[index])
        if not parsed or parsed["indent"] != env_indent + 2:
            continue
        env_key = parsed["key"].upper()
        if env_key in FORBIDDEN_ENV_KEYS or env_key.startswith("GIT_"):
            fail(f"{context}.env must not define {env_key}")
        if re.match(r'^BASH_FUNC_.*%%$', env_key):
            fail(f"{context}.env must not define Bash function export key {env_key}")


def step_env_values(step):
    values = {}
    for env_index in step["key_indexes"].get("env", []):
        env_end = block_end(env_index, 8, SCALAR_LINES)
        for index in range(env_index + 1, env_end):
            if SCALAR_LINES[index]:
                continue
            parsed = parse_key(lines[index])
            if parsed and parsed["indent"] == 10:
                values[parsed["key"]] = strip_quotes(parsed["value"])
    return values


def writes_execution_proof_output(run_lines):
    code_lines = [normalize_shell_words(line.split("#", 1)[0]) for line in executable_lines(run_lines)]
    joined = "\n".join(code_lines)
    lowered = joined.lower()
    proof_key_present = (
        "vt_g19_exec_proof" in joined
        or ("vt_g19" in lowered and "proof" in lowered)
        or ("vt_g19_exec" in lowered and "printf proof" in lowered)
    )
    output_path_present = (
        "GITHUB_OUTPUT" in joined
        or ("github_" in lowered and "output" in lowered)
        or ("printenv" in lowered and "output" in lowered)
    )
    output_write_present = (
        ">>" in joined
        or re.search(r'\btee\b.*\$', joined) is not None
        or "out-file" in lowered
    )
    if proof_key_present and output_path_present and output_write_present:
        return True
    return False


ALLOWED_GITHUB_PATH_PREFIX = re.compile(
    r"""^(?P<quote>['"])C:\\ProgramData\\chocolatey\\bin(?P=quote)\s*\|\s*Out-File\b(?P<tail>.*)$""",
    re.IGNORECASE,
)


def allowed_github_path_tail(tail):
    tokens = tail.split()
    seen = set()
    index = 0
    while index < len(tokens):
        token = tokens[index].lower()
        if token == "-append":
            seen.add("append")
            index += 1
            continue
        if token == "-filepath":
            if index + 1 >= len(tokens) or tokens[index + 1].lower() != "$env:github_path":
                return False
            seen.add("filepath")
            index += 2
            continue
        if token == "-encoding":
            if index + 1 >= len(tokens) or tokens[index + 1].lower() != "utf8":
                return False
            seen.add("encoding")
            index += 2
            continue
        return False
    return seen == {"append", "filepath", "encoding"}


def allowed_github_path_write(step, code):
    match = ALLOWED_GITHUB_PATH_PREFIX.match(code)
    return (
        step["name"] == "Install SQLite on Windows"
        and strip_quotes(step["keys"].get("if", "")) == "runner.os == 'Windows'"
        and strip_quotes(step["keys"].get("shell", "")) == "pwsh"
        and match is not None
        and allowed_github_path_tail(match.group("tail"))
    )


def forbidden_environment_mutation(step):
    raw_code_lines = [line.split("#", 1)[0].strip() for line in executable_lines(step["run_lines"])]
    code_lines = [normalize_shell_words(line) for line in raw_code_lines]
    for line in executable_lines(step["run_lines"]):
        if "\t" in line:
            return "tab-indented shell text"
        raw_code = line.split("#", 1)[0].strip()
        code = normalize_shell_words(raw_code)
        protected_paths = (
            ".github/workflows/ci.yml",
            "tests/run-gates.sh",
            "tests/g19-v2-structural-check.sh",
            "tests/lib/verify-tracked-workspace.sh",
            "memoriaia/verify/verify-hashchain.py",
            "verify/verify-hashchain.sh",
        )
        for protected_path in protected_paths:
            if protected_path in raw_code or protected_path in code:
                if re.search(r'(^|[;&|]\s*)(cp|mv|install|truncate|dd|tee)\b', code):
                    return "tracked gate file"
                if re.search(r'(^|[;&|]\s*)(cat|printf|echo|python[0-9.]*|node|perl|ruby|sed)\b', code) and re.search(r'(>>?|--in-place|-i\b)', code):
                    return "tracked gate file"
                if re.search(r'(^|[;&|]\s*):?\s*>{1,2}', raw_code):
                    return "tracked gate file"
        if step["name"] not in {GATE_STEP_NAME, SENTINEL_STEP_NAME}:
            if re.search(
                r'(^|[;&|]\s*)(?:(?:env|command|builtin)\s+)*(?:/usr/bin/|/bin/)?git(?:\s+-C\s+\S+)*\s+(checkout|switch|reset|clean|restore|update-ref|worktree|clone|fetch|pull|merge|rebase|submodule|apply|am|commit|add|rm|mv)\b',
                code,
            ):
                return "git checkout state"
            if "$(" in raw_code or "`" in raw_code:
                return "computed environment file"
            if re.search(r'(^|[;&|]\s*)(source|\.)\s+', code):
                return "computed environment file"
            if re.search(r'(^|[;&|]\s*)(?:/usr/bin/|/bin/)?(bash|sh|dash|zsh|ksh)\s+[^#;&|]*<\(', code):
                return "computed environment file"
        if re.search(r'(^|[^A-Za-z0-9_])eval\b', code):
            return "computed environment file"
        if re.search(r'(^|[;&|]\s*)\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(?=\s|$)', code):
            if re.search(r'(^|[;&|]\s*)\$\{?GIT_BIN\}?(\s|$)', code):
                continue
            return "computed environment file"
        if re.search(r'(^|[;&|]\s*)env\b[^#;&|]*\s(?:/usr/bin/|/bin/)?(bash|sh|dash|zsh|ksh)\s+[^#;&|]*-[A-Za-z]*c[A-Za-z]*(\s|$)', code):
            return "computed environment file"
        if re.search(r'(^|[;&|]\s*)(?:/usr/bin/|/bin/)?(bash|sh|dash|zsh|ksh)\s+[^#;&|]*-[A-Za-z]*c[A-Za-z]*(\s|$)', code):
            return "computed environment file"
        if re.search(r'(^|[;&|]\s*)(bash|sh|dash|zsh|ksh)\s+[^#;&|]*-[A-Za-z]*c[A-Za-z]*(\s|$)', code):
            return "computed environment file"
        if re.search(r'(^|[;&|]\s*)(python[0-9.]*|node|perl|ruby|php)\s+[^#;&|]*(?:-c|-e|-r)(\s|$)', code):
            return "computed environment file"
        if "GITHUB_ENV" in code:
            return "GITHUB_ENV"
        if "BASH_ENV" in code:
            return "BASH_ENV"
        if re.search(r'(^|[\s;])(export\s+)?GIT_(DIR|WORK_TREE|EXEC_PATH|INDEX_FILE|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|CONFIG[A-Za-z0-9_]*)=', code):
            return "GIT_*"
        if re.search(r'(^|[\s;])(export\s+)?(BASH_ENV|PATH|PYTHON|PYTHONPATH)=', code):
            return "shell environment"
        if "GITHUB_PATH" in raw_code or "GITHUB_PATH" in code:
            if allowed_github_path_write(step, raw_code):
                continue
            return "GITHUB_PATH"
    joined = "\n".join(code_lines)
    lowered = joined.lower()
    has_env_fragment = re.search(r'(^|[^a-z0-9_])env([^a-z0-9_]|$)', lowered) is not None
    has_path_fragment = re.search(r'(^|[^a-z0-9_])path([^a-z0-9_]|$)', lowered) is not None
    has_env_file_fragments = (
        ">>" in joined
        and (
            ("github" in lowered and has_env_fragment)
            or ("github" in lowered and has_path_fragment)
            or ("bash" in lowered and has_env_fragment)
        )
    )
    if has_env_file_fragments and not any(allowed_github_path_write(step, code) for code in raw_code_lines):
        return "environment file"
    if not any(allowed_github_path_write(step, code) for code in raw_code_lines):
        has_append = ">>" in joined or "out-file" in lowered
        has_indirect_lookup = (
            "printenv" in lowered
            or re.search(r'\$\{!\s*[A-Za-z_][A-Za-z0-9_]*\s*\}', joined) is not None
        )
        if has_append and has_indirect_lookup:
            return "computed environment file"
    return ""


ALLOWED_USES = {
    "actions/checkout@v4",
    "actions/setup-python@v5",
}


def inspect_uses_step(step):
    if "uses" not in step["keys"]:
        return
    uses_value = strip_quotes(step["keys"]["uses"])
    if uses_value not in ALLOWED_USES:
        fail(f"workflow uses step is not allowlisted: {uses_value}")
    if "run" in step["keys"]:
        fail(f"workflow step {step['name']} must not combine uses and run")


for env_index in top_env:
    inspect_env_block(env_index, 0, "workflow")


if top_jobs_index is not None:
    jobs_end = block_end(top_jobs_index, 0, SCALAR_LINES)
    gates = []
    for index in range(top_jobs_index + 1, jobs_end):
        if SCALAR_LINES[index]:
            continue
        parsed = parse_key(lines[index])
        if parsed and parsed["indent"] == 2 and parsed["key"] == "gates":
            gates.append((index, parsed["value"]))
    if len(gates) != 1:
        fail(f"expected exactly one top-level jobs.gates job, found {len(gates)}")
    else:
        gates_index, gates_value = gates[0]
        if gates_value.startswith("*"):
            fail("jobs.gates must not be a YAML alias")
        gates_end = block_end(gates_index, 2, SCALAR_LINES)
        reject_merge_keys(gates_index, gates_end, 2, "jobs.gates")
        gate_controls = collect_direct_controls(gates_index, gates_end, 2)
        for _, key, _ in gate_controls:
            if key in {"if", "continue-on-error", "needs"}:
                fail(f"job-level {key} found on gates job")
            if key == "working-directory":
                fail("job-level working-directory found on gates job")

        env_indexes = [index for index, key, _ in gate_controls if key == "env"]
        for env_index in env_indexes:
            inspect_env_block(env_index, 4, "jobs.gates")

        defaults_indexes = [index for index, key, _ in gate_controls if key == "defaults"]
        for defaults_index in defaults_indexes:
            defaults_value = parse_key(lines[defaults_index])["value"]
            if reject_inline_map_value("jobs.gates.defaults", defaults_value):
                continue
            defaults_end = block_end(defaults_index, 4, SCALAR_LINES)
            reject_merge_keys(defaults_index, defaults_end, 4, "jobs.gates.defaults")
            run_indexes = find_direct_child(defaults_index, defaults_end, 4, "run")
            for run_index in run_indexes:
                run_value = parse_key(lines[run_index])["value"]
                if reject_inline_map_value("jobs.gates.defaults.run", run_value):
                    continue
                run_end = block_end(run_index, 6, SCALAR_LINES)
                reject_merge_keys(run_index, run_end, 6, "jobs.gates.defaults.run")
                shell_indexes = find_direct_child(run_index, run_end, 6, "shell")
                workdir_indexes = find_direct_child(run_index, run_end, 6, "working-directory")
                if workdir_indexes:
                    fail("jobs.gates.defaults.run must not define working-directory")
                for shell_index in shell_indexes:
                    parsed = parse_key(lines[shell_index])
                    value = strip_quotes(parsed["value"])
                    if value != "bash":
                        fail("jobs.gates.defaults.run.shell must be exactly bash")
                    if contains_neutralizer(value):
                        fail("jobs.gates.defaults.run.shell contains a neutralizer")

        steps_indexes = find_direct_child(gates_index, gates_end, 2, "steps")
        if len(steps_indexes) != 1:
            fail(f"expected exactly one jobs.gates.steps block, found {len(steps_indexes)}")
            steps = []
        else:
            steps_index = steps_indexes[0]
            steps = parse_steps(steps_index, block_end(steps_index, 4, SCALAR_LINES))

        for step in steps:
            inspect_uses_step(step)
            if "working-directory" in step["keys"]:
                fail(f"workflow step {step['name']} must not define working-directory")
            for env_index in step["key_indexes"].get("env", []):
                inspect_env_block(env_index, 8, f"step {step['name']}")
            if writes_execution_proof_output(step["run_lines"]):
                fail("workflow must not write vt_g19_exec_proof directly through GITHUB_OUTPUT")
            env_mutation = forbidden_environment_mutation(step)
            if env_mutation:
                if step["name"] not in {GATE_STEP_NAME, SENTINEL_STEP_NAME} or env_mutation != "computed environment file":
                    fail(f"workflow must not mutate {env_mutation} in the gates job")

        gate_steps = [step for step in steps if step["name"] == GATE_STEP_NAME]
        sentinel_steps = [step for step in steps if step["name"] == SENTINEL_STEP_NAME]
        if len(gate_steps) != 1:
            fail(f"expected exactly one '{GATE_STEP_NAME}' step, found {len(gate_steps)}")
        if len(sentinel_steps) != 1:
            fail(f"expected exactly one '{SENTINEL_STEP_NAME}' step, found {len(sentinel_steps)}")

        if len(gate_steps) == 1:
            gate = gate_steps[0]
            gate_exec = executable_lines(gate["run_lines"])
            if gate["keys"].get("id", "").strip() != "run_gates":
                fail("gate execution step is missing id: run_gates")
            if "if" in gate["keys"]:
                fail("gate execution step must not define an if guard")
            if "continue-on-error" in gate["keys"]:
                fail("gate execution step must not define continue-on-error")
            if "shell" in gate["keys"] and strip_quotes(gate["keys"]["shell"]) != "bash":
                fail("gate execution step shell must be exactly bash when present")
            if "working-directory" in gate["keys"]:
                fail("gate execution step must not define working-directory")
            if gate["run_style"] == ">":
                fail("folded scalar run: > found on gate execution step")
            if any(contains_neutralizer(line) for line in gate_exec):
                fail("gate execution step contains gate-neutralizing pattern(s)")
            strict_gate_sequence = strict_workflow_proof or any("MATERIALIZED_WORKTREE" in line for line in gate_exec)
            if not strict_gate_sequence and gate_exec != ["bash tests/run-gates.sh"]:
                fail("gate run block must be exactly: bash tests/run-gates.sh")
            if strict_gate_sequence:
                expected_gate_exec = [
                    'ROOT_WORKSPACE="$PWD"',
                    'MATERIALIZED_WORKTREE="$(mktemp -d)"',
                    "cleanup_materialized_worktree() {",
                    'cd "$ROOT_WORKSPACE"',
                    'git worktree remove --force "$MATERIALIZED_WORKTREE" >/dev/null 2>&1 || rm -rf "$MATERIALIZED_WORKTREE"',
                    "}",
                    "trap cleanup_materialized_worktree EXIT",
                    "git config core.autocrlf false",
                    'git worktree add --detach "$MATERIALIZED_WORKTREE" "$VT_G19_CHECKOUT_SHA"',
                    'cd "$MATERIALIZED_WORKTREE"',
                    "git config core.autocrlf false",
                    'git reset --hard "$VT_G19_CHECKOUT_SHA"',
                    "source tests/lib/verify-tracked-workspace.sh",
                    "verify_tracked_workspace_file .github/workflows/ci.yml",
                    "verify_tracked_workspace_file tests/lib/verify-tracked-workspace.sh",
                    "verify_tracked_workspace_file tests/run-gates.sh",
                    "verify_tracked_workspace_file tests/g19-v2-structural-check.sh",
                    "verify_tracked_workspace_file memoriaia/verify/verify-hashchain.py",
                    "verify_tracked_workspace_file verify/verify-hashchain.sh",
                    "git ls-files 'tests/fixtures/g19-v2/*.yml' | while IFS= read -r fixture; do",
                    'verify_tracked_workspace_file "$fixture"',
                    "done",
                    "bash tests/run-gates.sh",
                ]
                allowed_gate_digests = {
                    "991cd5d874ac25b68142335282501e9746b6870480678a7536d38782ec63779e",
                }
                if gate_exec != expected_gate_exec and exec_digest(gate_exec) not in allowed_gate_digests:
                    fail("gate execution step must match the exact strict proof command sequence")
                for snippet in (
                    'ROOT_WORKSPACE="$PWD"',
                    'MATERIALIZED_WORKTREE="$(mktemp -d)"',
                    "config core.autocrlf false",
                    'worktree add --detach "$MATERIALIZED_WORKTREE" "$VT_G19_CHECKOUT_SHA"',
                    'cd "$MATERIALIZED_WORKTREE"',
                    "config core.autocrlf false",
                    'reset --hard "$VT_G19_CHECKOUT_SHA"',
                    "source ",
                    "verify_tracked_workspace_file .github/workflows/ci.yml",
                    "verify_tracked_workspace_file tests/lib/verify-tracked-workspace.sh",
                    "verify_tracked_workspace_file tests/run-gates.sh",
                    "verify_tracked_workspace_file tests/g19-v2-structural-check.sh",
                    "verify_tracked_workspace_file memoriaia/verify/verify-hashchain.py",
                    "verify_tracked_workspace_file verify/verify-hashchain.sh",
                    "verify_tracked_workspace_file \"$fixture\"",
                ):
                    if not any(snippet in line for line in gate_exec):
                        fail(f"gate execution step must verify workspace bytes before execution: {snippet}")
                fixture_verify_indexes = [
                    index
                    for index, line in enumerate(gate_exec)
                    if 'verify_tracked_workspace_file "$fixture"' in line
                ]
                if not fixture_verify_indexes:
                    fail("gate execution step must verify each fixture before execution")
                else:
                    last_fixture_verify_index = fixture_verify_indexes[-1]
                    if gate_exec[last_fixture_verify_index + 1 :] != ["done", "bash tests/run-gates.sh"]:
                        fail("gate execution step must execute run-gates immediately after final fixture verification")
                gate_env = step_env_values(gate)
                expected_event_env = {
                    "VT_G19_PR_HEAD_SHA": "${{ github.event.pull_request.head.sha || github.sha }}",
                    "VT_G19_PR_BASE_SHA": "${{ github.event.pull_request.base.sha || github.event.before || github.sha }}",
                    "VT_G19_CHECKOUT_SHA": "${{ github.sha }}",
                }
                for key, expected_value in expected_event_env.items():
                    if gate_env.get(key) != expected_value:
                        fail(f"gate execution step env must define {key} from GitHub event context")
                if exec_digest(gate_exec) in allowed_gate_digests and re.fullmatch(r'[0-9a-f]{64}', gate_env.get("VT_G19_EXPECTED_WORKSPACE_HELPER_SHA", "")) is None:
                    fail("gate execution step env must define VT_G19_EXPECTED_WORKSPACE_HELPER_SHA as a 64-hex hash")

        if len(sentinel_steps) == 1:
            sentinel = sentinel_steps[0]
            sentinel_exec = executable_lines(sentinel["run_lines"])
            sentinel_if = sentinel["keys"].get("if")
            if sentinel_if is None or sentinel_if.strip() != "always()":
                fail("sentinel step must define exactly if: always()")
            if "continue-on-error" in sentinel["keys"]:
                fail("sentinel step must not define continue-on-error")
            if "shell" in sentinel["keys"] and strip_quotes(sentinel["keys"]["shell"]) != "bash":
                fail("sentinel step shell must be exactly bash when present")
            if "working-directory" in sentinel["keys"]:
                fail("sentinel step must not define working-directory")
            if sentinel["run_style"] == ">":
                fail("folded scalar run: > found on sentinel step")
            if any("<<" in line for line in sentinel_exec):
                fail("G-19 execution path contains heredoc inert text")
            if contains_function_definition(sentinel_exec):
                fail("G-19 execution path contains uncalled shell function text")
            if contains_unsupported_sentinel_control(sentinel_exec):
                fail("G-19 execution path contains unsupported shell control flow")
            if any("trap" in line.split("#", 1)[0] for line in sentinel_exec):
                fail("G-19 execution path contains trap neutralizer(s)")
            if any(contains_neutralizer(line) for line in sentinel_exec):
                fail("G-19 execution path contains gate-neutralizing pattern(s)")
            if any(line in {"true", ":", "exit 0"} for line in sentinel_exec):
                fail("sentinel contains inert success command")
            if not strict_workflow_proof and any(
                re.search(
                    r'(^|[;&|]\s*)(?:(?:exec|builtin|command)\s+)*(?:/usr/bin/|/bin/)?(touch|cp|mv|rm|printf|echo|python[0-9.]*|node|perl|ruby|sed|cat|tee|bash|sh|git)\b',
                    line,
                )
                for line in sentinel_exec
            ):
                fail("sentinel contains side-effecting command outside the proof contract")
            bad_exits = [line for line in sentinel_exec if re.match(r'^exit\b', line) and line != "exit 1"]
            if bad_exits:
                fail("sentinel failure branches must terminate with literal exit 1")

            proof_assignments = [line for line in sentinel_exec if re.match(r'^PROOF=', line)]
            if len(proof_assignments) != 1 or not PROOF_ASSIGNMENT_PATTERN.match(proof_assignments[0]):
                fail("sentinel must read vt_g19_exec_proof exactly once and preserve it")
            if proof_mutation_lines(sentinel_exec):
                fail("sentinel must not mutate PROOF after reading vt_g19_exec_proof")
            expected_proof_assignments_any = [line for line in sentinel_exec if re.match(r'^EXPECTED_PROOF=', line)]
            if len(expected_proof_assignments_any) > 1:
                fail("sentinel must not rewrite EXPECTED_PROOF after computing it")
            if len(expected_proof_assignments_any) == 1 and "VT_G19_EXECUTED:v4" not in expected_proof_assignments_any[0]:
                fail("sentinel EXPECTED_PROOF must use v4 proof preimage")
            outcome_pattern = re.compile(r'^if \[ "\$\{\{\s*steps\.run_gates\.outcome\s*\}\}" != "success" \]; then$')
            missing_pattern = re.compile(r'^if \[ -z "\$PROOF" \]; then$')
            invalid_pattern = re.compile(r"^if ! printf '%s\\n' \"\$PROOF\" \| grep -qE '\^\[0-9a-f\]\{64\}\$'; then$")
            pr_head_sha_pattern = re.compile(r"^if ! printf '%s\\n' \"\$VT_G19_PR_HEAD_SHA\" \| grep -qE '\^\[0-9a-f\]\{40\}\$'; then$")
            pr_base_sha_pattern = re.compile(r"^if ! printf '%s\\n' \"\$VT_G19_PR_BASE_SHA\" \| grep -qE '\^\[0-9a-f\]\{40\}\$'; then$")
            checkout_sha_pattern = re.compile(r"^if ! printf '%s\\n' \"\$VT_G19_CHECKOUT_SHA\" \| grep -qE '\^\[0-9a-f\]\{40\}\$'; then$")
            checkout_match_pattern = re.compile(r'^if \[ "\$CHECKOUT_SHA" != "\$VT_G19_CHECKOUT_SHA" \]; then$')
            run_gates_hash_pattern = re.compile(r'^if \[ "\$RUN_GATES_SHA" != "\$VT_G19_EXPECTED_RUN_GATES_SHA" \]; then$')
            structural_hash_pattern = re.compile(r'^if \[ "\$STRUCTURAL_CHECK_SHA" != "\$VT_G19_EXPECTED_STRUCTURAL_CHECK_SHA" \]; then$')
            workspace_helper_hash_pattern = re.compile(r'^if \[ "\$WORKSPACE_HELPER_SHA" != "\$VT_G19_EXPECTED_WORKSPACE_HELPER_SHA" \]; then$')
            verify_py_hash_pattern = re.compile(r'^if \[ "\$VERIFY_PY_SHA" != "\$VT_G19_EXPECTED_VERIFY_PY_SHA" \]; then$')
            verify_sh_hash_pattern = re.compile(r'^if \[ "\$VERIFY_SH_SHA" != "\$VT_G19_EXPECTED_VERIFY_SH_SHA" \]; then$')
            fixture_hash_pattern = re.compile(r'^if \[ "\$FIXTURE_MANIFEST_SHA" != "\$VT_G19_EXPECTED_FIXTURE_MANIFEST_SHA" \]; then$')
            proof_preimage_pattern = re.compile(r'^if \[ "\$PROOF" != "\$EXPECTED_PROOF" \]; then$')
            require_top_level_branch(sentinel_exec, outcome_pattern, "steps.run_gates.outcome")
            require_top_level_branch(sentinel_exec, missing_pattern, "missing execution proof")
            require_top_level_branch(sentinel_exec, invalid_pattern, "invalid execution proof")
            if strict_workflow_proof:
                expected_sentinel_exec = [
                    'if [ "${{ steps.run_gates.outcome }}" != "success" ]; then',
                    'echo "G-19 FAIL: tests/run-gates.sh did not complete successfully (outcome: ${{ steps.run_gates.outcome }})"',
                    "exit 1",
                    "fi",
                    'if ! printf \'%s\\n\' "$VT_G19_PR_HEAD_SHA" | grep -qE \'^[0-9a-f]{40}$\'; then',
                    'echo "G-19 FAIL: PR head SHA is invalid ($VT_G19_PR_HEAD_SHA)"',
                    "exit 1",
                    "fi",
                    'if ! printf \'%s\\n\' "$VT_G19_PR_BASE_SHA" | grep -qE \'^[0-9a-f]{40}$\'; then',
                    'echo "G-19 FAIL: PR base SHA is invalid ($VT_G19_PR_BASE_SHA)"',
                    "exit 1",
                    "fi",
                    'if ! printf \'%s\\n\' "$VT_G19_CHECKOUT_SHA" | grep -qE \'^[0-9a-f]{40}$\'; then',
                    'echo "G-19 FAIL: checkout SHA is invalid ($VT_G19_CHECKOUT_SHA)"',
                    "exit 1",
                    "fi",
                    'CHECKOUT_SHA="$(git rev-parse HEAD)"',
                    'if [ "$CHECKOUT_SHA" != "$VT_G19_CHECKOUT_SHA" ]; then',
                    'echo "G-19 FAIL: checkout SHA mismatch (expected $VT_G19_CHECKOUT_SHA, got $CHECKOUT_SHA)"',
                    "exit 1",
                    "fi",
                    'RUN_GATES_SHA="$(git cat-file blob "$CHECKOUT_SHA:tests/run-gates.sh" | sha256sum | awk \'{print $1}\')"',
                    'if [ "$RUN_GATES_SHA" != "$VT_G19_EXPECTED_RUN_GATES_SHA" ]; then',
                    'echo "G-19 FAIL: tests/run-gates.sh hash mismatch ($RUN_GATES_SHA)"',
                    "exit 1",
                    "fi",
                    'STRUCTURAL_CHECK_SHA="$(git cat-file blob "$CHECKOUT_SHA:tests/g19-v2-structural-check.sh" | sha256sum | awk \'{print $1}\')"',
                    'if [ "$STRUCTURAL_CHECK_SHA" != "$VT_G19_EXPECTED_STRUCTURAL_CHECK_SHA" ]; then',
                    'echo "G-19 FAIL: tests/g19-v2-structural-check.sh hash mismatch ($STRUCTURAL_CHECK_SHA)"',
                    "exit 1",
                    "fi",
                    'WORKSPACE_HELPER_SHA="$(git cat-file blob "$CHECKOUT_SHA:tests/lib/verify-tracked-workspace.sh" | sha256sum | awk \'{print $1}\')"',
                    'if [ "$WORKSPACE_HELPER_SHA" != "$VT_G19_EXPECTED_WORKSPACE_HELPER_SHA" ]; then',
                    'echo "G-19 FAIL: tests/lib/verify-tracked-workspace.sh hash mismatch ($WORKSPACE_HELPER_SHA)"',
                    "exit 1",
                    "fi",
                    'CI_YML_SHA="$(git cat-file blob "$CHECKOUT_SHA:.github/workflows/ci.yml" | sha256sum | awk \'{print $1}\')"',
                    'VERIFY_PY_SHA="$(git cat-file blob "$CHECKOUT_SHA:memoriaia/verify/verify-hashchain.py" | sha256sum | awk \'{print $1}\')"',
                    'if [ "$VERIFY_PY_SHA" != "$VT_G19_EXPECTED_VERIFY_PY_SHA" ]; then',
                    'echo "G-19 FAIL: memoriaia/verify/verify-hashchain.py hash mismatch ($VERIFY_PY_SHA)"',
                    "exit 1",
                    "fi",
                    'VERIFY_SH_SHA="$(git cat-file blob "$CHECKOUT_SHA:verify/verify-hashchain.sh" | sha256sum | awk \'{print $1}\')"',
                    'if [ "$VERIFY_SH_SHA" != "$VT_G19_EXPECTED_VERIFY_SH_SHA" ]; then',
                    'echo "G-19 FAIL: verify/verify-hashchain.sh hash mismatch ($VERIFY_SH_SHA)"',
                    "exit 1",
                    "fi",
                    'FIXTURE_MANIFEST_SHA="$(git ls-files \'tests/fixtures/g19-v2/*.yml\' | while IFS= read -r fixture; do fixture_sha="$(git cat-file blob "$CHECKOUT_SHA:$fixture" | sha256sum | awk \'{print $1}\')"; printf \'%s  %s\\n\' "$fixture_sha" "$fixture"; done | sha256sum | awk \'{print $1}\')"',
                    'if [ "$FIXTURE_MANIFEST_SHA" != "$VT_G19_EXPECTED_FIXTURE_MANIFEST_SHA" ]; then',
                    'echo "G-19 FAIL: G-19 fixture manifest hash mismatch ($FIXTURE_MANIFEST_SHA)"',
                    "exit 1",
                    "fi",
                    'PROOF="${{ steps.run_gates.outputs.vt_g19_exec_proof }}"',
                    'if [ -z "$PROOF" ]; then',
                    'echo "G-19 FAIL: VT_G19_EXEC_PROOF is missing"',
                    "exit 1",
                    "fi",
                    'if ! printf \'%s\\n\' "$PROOF" | grep -qE \'^[0-9a-f]{64}$\'; then',
                    'echo "G-19 FAIL: VT_G19_EXEC_PROOF is invalid ($PROOF)"',
                    "exit 1",
                    "fi",
                    'EXPECTED_PROOF="$(printf \'VT_G19_EXECUTED:v4\\nPR_HEAD:%s\\nPR_BASE:%s\\nCHECKOUT:%s\\nCI_YML:%s\\nRUN_GATES:%s\\nSTRUCTURAL:%s\\nWORKSPACE_HELPER:%s\\nVERIFY_PY:%s\\nVERIFY_SH:%s\\nFIXTURES:%s\\n\' "$VT_G19_PR_HEAD_SHA" "$VT_G19_PR_BASE_SHA" "$CHECKOUT_SHA" "$CI_YML_SHA" "$RUN_GATES_SHA" "$STRUCTURAL_CHECK_SHA" "$WORKSPACE_HELPER_SHA" "$VERIFY_PY_SHA" "$VERIFY_SH_SHA" "$FIXTURE_MANIFEST_SHA" | sha256sum | awk \'{print $1}\')"',
                    'if [ "$PROOF" != "$EXPECTED_PROOF" ]; then',
                    'echo "G-19 FAIL: VT_G19_EXEC_PROOF preimage mismatch (expected $EXPECTED_PROOF, got $PROOF)"',
                    "exit 1",
                    "fi",
                    'echo "G-19 PASS: PR head $VT_G19_PR_HEAD_SHA; base $VT_G19_PR_BASE_SHA; checkout $CHECKOUT_SHA"',
                    'echo "G-19 PASS: Execution proved ($PROOF)"',
                ]
                allowed_sentinel_digests = {
                    "1acf0ea25bda4e6a90dd5eec47abdaccf9fcd0f5f7d3550147ad39390d47c38e",
                }
                if sentinel_exec != expected_sentinel_exec and exec_digest(sentinel_exec) not in allowed_sentinel_digests:
                    fail("sentinel step must match the exact strict proof command sequence")
                expected_proof_assignments = [line for line in sentinel_exec if re.match(r'^EXPECTED_PROOF=', line)]
                if len(expected_proof_assignments) != 1 or not expected_proof_assignments[0].startswith('EXPECTED_PROOF="$(printf '):
                    fail("sentinel must compute EXPECTED_PROOF exactly once from the v4 preimage")
                for material_key in (
                    "CHECKOUT_SHA",
                    "CI_YML_SHA",
                    "RUN_GATES_SHA",
                    "STRUCTURAL_CHECK_SHA",
                    "WORKSPACE_HELPER_SHA",
                    "VERIFY_PY_SHA",
                    "VERIFY_SH_SHA",
                    "FIXTURE_MANIFEST_SHA",
                ):
                    count = sum(1 for line in sentinel_exec if re.match(rf'^{material_key}=', line))
                    if count != 1:
                        fail(f"sentinel must assign {material_key} exactly once")
                require_top_level_branch(sentinel_exec, pr_head_sha_pattern, "PR head SHA")
                require_top_level_branch(sentinel_exec, pr_base_sha_pattern, "PR base SHA")
                require_top_level_branch(sentinel_exec, checkout_sha_pattern, "checkout SHA")
                require_top_level_branch(sentinel_exec, checkout_match_pattern, "checked-out SHA")
                require_top_level_branch(sentinel_exec, run_gates_hash_pattern, "tests/run-gates.sh content hash")
                require_top_level_branch(sentinel_exec, structural_hash_pattern, "tests/g19-v2-structural-check.sh content hash")
                require_top_level_branch(sentinel_exec, workspace_helper_hash_pattern, "tests/lib/verify-tracked-workspace.sh content hash")
                require_top_level_branch(sentinel_exec, verify_py_hash_pattern, "Python verifier content hash")
                require_top_level_branch(sentinel_exec, verify_sh_hash_pattern, "bash verifier content hash")
                require_top_level_branch(sentinel_exec, fixture_hash_pattern, "G-19 fixture manifest hash")
                require_top_level_branch(sentinel_exec, proof_preimage_pattern, "execution proof preimage")
                sentinel_env = step_env_values(sentinel)
                expected_event_env = {
                    "VT_G19_PR_HEAD_SHA": "${{ github.event.pull_request.head.sha || github.sha }}",
                    "VT_G19_PR_BASE_SHA": "${{ github.event.pull_request.base.sha || github.event.before || github.sha }}",
                    "VT_G19_CHECKOUT_SHA": "${{ github.sha }}",
                }
                for key, expected_value in expected_event_env.items():
                    if sentinel_env.get(key) != expected_value:
                        fail(f"sentinel env must define {key} from GitHub event context")
                for key in (
                    "VT_G19_EXPECTED_RUN_GATES_SHA",
                    "VT_G19_EXPECTED_STRUCTURAL_CHECK_SHA",
                    "VT_G19_EXPECTED_WORKSPACE_HELPER_SHA",
                    "VT_G19_EXPECTED_VERIFY_PY_SHA",
                    "VT_G19_EXPECTED_VERIFY_SH_SHA",
                    "VT_G19_EXPECTED_FIXTURE_MANIFEST_SHA",
                ):
                    if re.fullmatch(r'[0-9a-f]{64}', sentinel_env.get(key, "")) is None:
                        fail(f"sentinel env must define {key} as a 64-hex hash")
                for snippet in (
                    'cat-file blob "$CHECKOUT_SHA:tests/run-gates.sh"',
                    'cat-file blob "$CHECKOUT_SHA:tests/g19-v2-structural-check.sh"',
                    'cat-file blob "$CHECKOUT_SHA:tests/lib/verify-tracked-workspace.sh"',
                    'cat-file blob "$CHECKOUT_SHA:.github/workflows/ci.yml"',
                    'cat-file blob "$CHECKOUT_SHA:memoriaia/verify/verify-hashchain.py"',
                    'cat-file blob "$CHECKOUT_SHA:verify/verify-hashchain.sh"',
                    'ls-files \'tests/fixtures/g19-v2/*.yml\'',
                    'cat-file blob "$CHECKOUT_SHA:$fixture"',
                ):
                    if not any(snippet in line for line in sentinel_exec):
                        fail(f"sentinel must compute proof material from Git blob input: {snippet}")
                expected_proof_lines = [line for line in sentinel_exec if line.startswith('EXPECTED_PROOF="$(printf ')]
                if not expected_proof_lines or "VT_G19_EXECUTED:v4" not in expected_proof_lines[0]:
                    fail("sentinel must recompute v4 VT_G19_EXEC_PROOF preimage")
                for snippet in ("PR_HEAD:%s", "PR_BASE:%s", "CHECKOUT:%s", "CI_YML:%s", "RUN_GATES:%s", "STRUCTURAL:%s", "WORKSPACE_HELPER:%s", "VERIFY_PY:%s", "VERIFY_SH:%s", "FIXTURES:%s"):
                    if not any(snippet in line for line in expected_proof_lines):
                        fail(f"sentinel proof preimage must include {snippet}")

if errors:
    for error in errors:
        print(f"G-19 FAIL: {error}")
    sys.exit(1)

print("G-19 STRUCTURAL CHECK PASS")
PY
