"""
    Reads the Avorion script API documentation (HTML) and generates EmmyLua
    type-annotation stubs for IntelliJ/EmmyLua intellisense.

    Original author: Rian Drake (riandrake) -- https://github.com/riandrake/AvorionModTools
    Adapted for avorion-omnihub: reads docs in-place from a path/env var (no
    copying), emits snake_case stub files, richer ---@field/---@param typing,
    void-return handling, forward declarations, and description-driven type
    refinement for `var`/`any` parameters.

    Usage:
        python stub_generator.py [DOCS_DIR] [OUT_DIR]
        python stub_generator.py --docs <path> --out <path>

    DOCS_DIR resolution order: positional/--docs arg, then $AVORION_DOCS_DIR,
    then $AVORION_DATA_DIR/../documentation. OUT_DIR defaults to ./stubs/generated.
"""
from pathlib import Path
from dataclasses import dataclass
from bs4 import BeautifulSoup
import argparse
import os
import re
import sys


class StubGeneratorError(Exception):
    """ Custom Exception Class """
    pass


# Output directory for generated stubs. Set by main() before run().
STUBS_DIR = None

DEFAULT_VALUES_BY_TYPE = {
    '': 'nil',
    'bool': 'true',
    'string': '""',
    'int': '0',
    'unsigned': '0',
    'float': '0.0',
    'var': 'nil',
    'double': '0.0',
    'Uuid': '0',
    'uuid': '0',
    'char': '""',
    'table': '{}',
    'table_t': '{}',
    'pair': '{}',
    'string_pair': '{}',
    'int_map_type': '{}',
    'Coordinates': '0, 0',
    'Member': 'AllianceMember()',
    'Resources': '{0}',
    'bitset<10>': '{0}',
    'Type': 'ComponentType'
}

RAW_DEFAULT_VALUES_BY_TYPE = {
    '': '',
    'bool': 'boolean',
    'string': 'string',
    'int': 'integer',
    'unsigned': 'integer',
    'float': 'number',
    'var': 'any',
    'double': 'number',
    'uuid': 'Uuid',
    'Uuid': 'Uuid',
    'table': 'table',
    'table_t': 'table',
    'char': 'string',
    'pair': 'table',
    'string_pair': 'table',
    'int_map_type': 'table',
    'gutBuildError': 'any',
    'void': 'nil',
    'nothing': 'nil',
    'Coordinates': 'integer, integer',
    'Member': 'AllianceMember',
    'Resources': 'table<number, number>',
    'string or Format [optional]': 'string, Format',
    'string or Format': 'string, Format',
    '[or nil]': 'nil',
    'bitset<10>': 'integer',
    'Type': 'ComponentType'
}

# Lua primitive / pseudo types that never need a ---@class declaration.
PRIMITIVES = {
    '', 'any', 'nil', 'boolean', 'string', 'number', 'integer', 'table',
    'void', 'self', 'fun', 'function', 'thread', 'userdata', 'lightuserdata',
}

# Lowercase engine math types that have no dedicated doc page but are referenced
# widely; always forward-declare them if seen.
MATH_TYPES = {
    'vec2', 'vec3', 'vec4', 'ivec2', 'ivec3', 'ivec4',
    'dvec2', 'dvec3', 'dvec4', 'quat', 'mat3', 'mat4',
}

# Referenced types that are really integer handles/enums — alias instead of class.
TYPE_ALIASES = {'Uuid': 'integer', 'ComponentType': 'integer'}

# C++ qualifiers that leak from some signatures and must be dropped.
QUALIFIERS = {'const', 'static', 'auto', 'mutable', 'volatile', 'inline'}

# Engine globals and variables that have NO dedicated documentation page, so the
# parser cannot produce them. Hand-maintained here and emitted verbatim on every
# run (as _extras.lua) so the generated stub set is self-contained — this is what
# lets the project drop the previously hand-written stubs entirely.
EXTRAS_LUA = '''\
-- Engine globals/variables with no documentation page. Hand-maintained in
-- stub_generator.py (EXTRAS_LUA) and regenerated on every run.

--- Load a Lua library through Avorion's VFS (mod fragments are injected before
--- load). Use this, never `require`. Returns nil, a module table, or a
--- constructor depending on the library.
---@param libraryName string
---@return any
function include(libraryName) end

--- Mark a namespace function as remotely callable via invokeServerFunction /
--- invokeClientFunction. Must be called at file scope.
---@param namespace table
---@param functionName string
function callable(namespace, functionName) end

--- Display a tooltip string at the current mouse position (client only).
---@param text string
function drawMouseTooltip(text) end

--- Draw a 3D sphere in world space for one frame (client only).
---@param position vec3
---@param radius number
---@param color Color
function drawSphere(position, radius, color) end

---@overload fun(x: number, y: number, z: number, w: number): quat
---@return quat
function quat() end

--- Index of the player whose RPC triggered the current server-side call. Only
--- valid inside a function invoked via invokeServerFunction.
---@type integer
callingPlayer = 0

--- Localization marker for the string modulo operator: `"Hello" % _t`.
---@type boolean
_t = true

--- Upper-case localization marker (forces the first letter uppercase).
---@type boolean
_T = true
'''

# Heuristics to recover a real type for `var`-typed (i.e. `any`) parameters from
# their doc description. Each entry is (regex on the lowercased description,
# lua type). Applied IN ORDER, first match wins, and ONLY when the parsed type
# is still `any` — so a known type is never downgraded. Keep patterns
# high-confidence; a wrong guess is worse than `any`.
DESCRIPTION_TYPE_HINTS = [
    # entity references
    (r'\bid of the entity\b', 'Entity|Uuid'),
    (r'\bid of an existing entity\b', 'Entity|Uuid'),
    (r"\bentity'?s? id\b", 'Entity|Uuid'),
    (r'\bentity (this|the) component belongs to\b', 'Entity|Uuid'),
    (r'\buuid of\b', 'Uuid'),
    # known engine enums
    (r'\btype of damage\b', 'DamageType'),
    (r'\bsource of (the )?damage\b', 'DamageSource'),
    (r'\barrival type\b', 'EntityArrivalType'),
    # goods
    (r'\beither a tradinggood\b', 'TradingGood|string'),
    (r'\btradinggood or a string\b', 'TradingGood|string'),
    # names / identifiers
    (r'\bname or index\b', 'string|integer'),
    (r'\ba string or int\b', 'string|integer'),
    (r'\bname of the (function|script|callback)\b', 'string'),
    # vectors (vec3 is the dominant case across the math API)
    (r'\bvector [ab]\b', 'vec3'),
    (r'^the vector\b', 'vec3'),
    # booleans phrased in prose
    (r'\bset to true\b', 'boolean'),
    (r'\ba bool\b', 'boolean'),
    (r'\bindicating (whether|if)\b', 'boolean'),
]
DESCRIPTION_TYPE_HINTS = [(re.compile(pat), t) for pat, t in DESCRIPTION_TYPE_HINTS]

# Single-letter parameters that are virtually always plain numbers.
NUMERIC_PARAM_NAMES = {'x', 'y', 'z', 'w'}


def refine_param_type(name, current, description):
    """ Upgrade an `any`/`var` parameter type using its name and doc
        description. Returns `current` unchanged for any already-known type. """
    if current not in ('any', 'var'):
        return current
    if name in NUMERIC_PARAM_NAMES:
        return 'number'
    if name.endswith('Index'):
        return 'integer'
    desc = (description or '').lower()
    for pattern, lua_type in DESCRIPTION_TYPE_HINTS:
        if pattern.search(desc):
            return lua_type
    return current


# Description phrases that mark a parameter as optional (nil/omittable).
OPTIONAL_DESC_RE = re.compile(
    r'\boptional\b|\bor nil\b|\bif nil\b|\bnil for the\b|\bcan be (nil|omitted)\b'
    r'|\bif (not |un)(set|specified|given|provided)\b|\bdefaults? to\b'
    r'|\bleave (it )?(empty|nil|blank)\b')


def is_optional_param(ptype, description):
    """ Whether a parameter may be omitted. Entity-id constructor args are
        always optional (omitting them targets the current script-context
        entity, e.g. `Entity()`, `Plan()`, `CargoBay()`); otherwise fall back
        to optionality phrasing in the description. """
    if ptype == 'Entity|Uuid':
        return True
    return bool(OPTIONAL_DESC_RE.search((description or '').lower()))


def split_careful(s, split=','):
    """
    :param s: input string
    :param split: input split string
    :return: a comma-delimited argument list, with exceptions for commas found within brackets
    """
    parts = []
    bracket_level = 0
    current = []
    for c in (s + split):
        if c == split and bracket_level == 0:
            if current:
                back = "".join(current)
                assert (back)
                parts.append(back)
                current = []
        else:
            if c in "{<[":
                bracket_level += 1
            elif c in "}>]":
                bracket_level -= 1
            current.append(c)

    assert (bracket_level == 0)
    return parts


_SNAKE_RE_1 = re.compile(r'(.)([A-Z][a-z]+)')
_SNAKE_RE_2 = re.compile(r'([a-z0-9])([A-Z])')


def to_snake_case(name):
    """ Convert an API type name to a snake_case file stem, keeping runs of
        capital letters (acronyms such as AI, UI, FX) together.
        ReadOnlyVelocity -> read_only_velocity ; TorpedoAI -> torpedo_ai ;
        GlowFX -> glow_fx ; UIVerticalSplitter -> ui_vertical_splitter """
    s = _SNAKE_RE_1.sub(r'\1_\2', name)
    s = _SNAKE_RE_2.sub(r'\1_\2', s)
    return s.lower()


def indent(string):
    """
    :param string: a block of text
    :return: the same block of text, indented
    """
    lines = string.split('\n')
    for idx, line in enumerate(lines):
        if line.strip():
            lines[idx] = '\t' + line
    return '\n'.join(lines)


def old_get_default_value(in_type):
    """
    :param in_type: the lua type, as a string
    :return: the default value placeholder assigned to this type
    """
    in_type = in_type.strip()

    if '{' in in_type:
        between = in_type[1:-1]
        between_args = [subarg for subarg in split_careful(between) if subarg.strip()]
        return '{' + ', '.join((get_default_value(arg) for arg in between_args)) + '}'

    in_type = in_type.replace('::', '')

    global DEFAULT_VALUES_BY_TYPE
    if in_type not in DEFAULT_VALUES_BY_TYPE:
        for weird in ('=', ' '):
            if weird in in_type:
                print(f'Weird type: "{in_type}"')
                return 'nil'
        DEFAULT_VALUES_BY_TYPE[in_type] = in_type + '()'

    return DEFAULT_VALUES_BY_TYPE[in_type]


def get_default_value(in_type):
    """
    :param in_type: the lua type, as a string
    :return: the default value placeholder assigned to this type
    """
    if not in_type:
        return 'nil'

    if not 'table<' in in_type:
        in_type = in_type.replace(',', '')
    else:
        in_type = f'table<{",".join([get_default_value(val.strip()) for val in split_careful(in_type.replace("table<", "").replace(">", ""))])}>'

    if '...' in in_type:
        in_type = f"table<{get_default_value(in_type.replace('...', ''))}>"

    in_type = in_type.replace('::', '')

    global DEFAULT_VALUES_BY_TYPE
    if in_type not in DEFAULT_VALUES_BY_TYPE:
        for weird in ('=', ' '):
            if weird in in_type and 'table' not in in_type:
                print(f'Weird type: "{in_type}"')
                return 'nil'
        DEFAULT_VALUES_BY_TYPE[in_type] = in_type.replace('table<', '{').replace('>', '}')
    return DEFAULT_VALUES_BY_TYPE[in_type]


def get_raw_default_value(in_type):
    """
    :param in_type: the lua type, as a string
    :return: the raw default value placeholder assigned to this type
    """
    if not in_type:
        return ''

    # Drop C++ namespace/qualifier noise that leaks from a few signatures.
    in_type = in_type.replace('std::string', 'string').replace('std::', '')
    for qual in QUALIFIERS:
        in_type = re.sub(r'\b' + qual + r'\b', '', in_type).strip()
    if not in_type:
        return ''

    if not 'table<' in in_type:
        in_type = in_type.replace(',', '')
    else:
        test = f'table<{",".join([get_raw_default_value(val.strip()) for val in split_careful(in_type[in_type.find("<") + 1:in_type.rfind(">")])])}>'
        return test

    if 'plan...' in in_type:
        in_type = 'table_of_plans'
    if '...' in in_type:
        in_type = f"table<number, {get_raw_default_value(in_type.replace('...', ''))}>"

    in_type = in_type.replace('::', '')

    global RAW_DEFAULT_VALUES_BY_TYPE
    if in_type not in RAW_DEFAULT_VALUES_BY_TYPE:
        for weird in ('=', ' '):
            if weird in in_type and 'table' not in in_type:
                print(f'Weird type: "{in_type}"')
                return 'nil'
        RAW_DEFAULT_VALUES_BY_TYPE[in_type] = in_type
    return RAW_DEFAULT_VALUES_BY_TYPE[in_type]


def old_get_raw_default_value(in_type):
    in_type = in_type.strip()

    if '{' in in_type:
        between = in_type[1:-1]
        between_args = [subarg for subarg in split_careful(between) if subarg.strip()]
        return '{' + ', '.join((get_raw_default_value(arg) for arg in between_args)) + '}'

    in_type = in_type.replace('::', '')

    in_type = f'table<number,{in_type}>' if in_type.find('...') > 0 else in_type
    in_type = in_type.replace('...', '')

    global RAW_DEFAULT_VALUES_BY_TYPE
    if in_type not in RAW_DEFAULT_VALUES_BY_TYPE:
        for weird in ('=', ' '):
            if weird in in_type:
                print(f'Weird type: "{in_type}"')
                return 'nil'
        RAW_DEFAULT_VALUES_BY_TYPE[in_type] = in_type

    return RAW_DEFAULT_VALUES_BY_TYPE[in_type]


def old_flip_args(arg):
    if ' ' in arg:
        arg = arg.split()
        arg.reverse()
        if len(arg) > 1:
            arg[1] = get_raw_default_value(arg[1])
        arg = ':'.join(arg)
    return arg


def flip_args(args):
    args = split_careful(args)
    for idx, arg in enumerate(args):
        arg = [t for t in split_careful(arg, ' ') if t not in QUALIFIERS]
        arg.reverse()
        for idx2, arg2 in enumerate(arg):
            arg[idx2] = get_raw_default_value(arg2)
        args[idx] = ' '.join(arg)
    return args


@dataclass(init=False)
class ParsedProperty:
    """ Property parser from Avorion documentation """
    type: str
    name: str
    remark: str

    def __lt__(self, other):
        return self.name < other.name

    def parse_property(self, in_property):
        """ Parse a property from documentation """
        tag_begin = in_property.find('[')
        if tag_begin != -1:
            self.remark = in_property[tag_begin:in_property.rfind(']') + 1] + ' '
            in_property = in_property[:tag_begin]
        else:
            self.remark = ''

        words = in_property.split()[1:]
        self.name = words[-1]
        self.type = ' '.join(words[:-1]).strip().replace('\n', '')

        for strip in ('...', 'static '):
            self.type = self.type.replace(strip, '')


@dataclass(init=False)
class ParsedFunction:
    """ Function parser from Avorion documentation """
    name: str
    definition: str
    remarks: str
    callback: bool
    return_value: str
    raw_return_value: str
    arguments: str

    def __lt__(self, other):
        return self.name < other.name

    def parse_return_value(self, return_value):
        """ Parse a return value for defaults """
        for strip in ('...', 'static ', 'const '):
            return_value = return_value.replace(strip, '')

        return_value = return_value.replace('table<', '{')
        return_value = return_value.replace('>', '}')

        return_values = split_careful(return_value)

        raw_return_values = return_values.copy()
        for idx, _type in enumerate(raw_return_values):
            raw_return_values[idx] = get_raw_default_value(_type)

        self.raw_return_value = ', '.join(raw_return_values)

        for idx, _type in enumerate(return_values):
            return_values[idx] = get_default_value(_type)

        self.return_value = ', '.join(return_values)

    def old_parse_definition(self, definition, namespace):
        """ Parse a definition from documentation """
        self.callback = definition.startswith('callback ')

        end_bracket = definition.rfind(')')
        start_bracket = definition.rfind('(', 0, end_bracket)

        args = definition[start_bracket + 1:end_bracket]
        args = split_careful(args)
        arg_types = []

        for idx, arg in enumerate(args):
            if split := arg.split():
                arg = split[-1]
                if len(split) > 1:
                    arg_types.append('---@param ' + arg + ' ' + split[0] + '\n')

            arg = arg.strip()

            if arg in ('in', 'function'):
                arg = '_' + arg

            for illegal in ('...'):
                arg = arg.replace(illegal, '')

            args[idx] = arg

        args = [arg.strip() for arg in args if arg.strip()]
        self.arguments = ', '.join(args)

        name_start = definition.rfind(' ', 0, start_bracket)

        self.name = definition[name_start + 1:start_bracket]

        prefix_len = len('callback ' if self.callback else 'function ')
        self.parse_return_value(definition[prefix_len:name_start])

        namespace = namespace + ':' if namespace else ''

        param_type = self.raw_return_value
        param_type = param_type.replace('{', 'table<')
        param_type = param_type.replace('}', '>')

        param_args = definition[start_bracket + 1:end_bracket]
        if ',' in param_args:
            param_args = param_args.split(', ')
            for idx, arg in enumerate(param_args):
                param_args[idx] = flip_args(arg)
            param_args = ', '.join(param_args)
        else:
            param_args = flip_args(param_args)

        param_type = f'---@type fun({param_args}){":" + param_type if param_type else ""}\n'

        self.definition = param_type + f'{namespace.replace(":", ".")}{self.name} = function ({", ".join(args)})\n\treturn {self.return_value}\nend\n\n'

    def parse_definition(self, definition, namespace):
        """ Parse a definition from documentation """
        self.callback = definition.startswith('callback ')

        # Docs notate untyped maps as `table[dir -> value]`; the placeholders are
        # descriptive words, not real types, so collapse to a plain table.
        definition = re.sub(r'table\[[^\]]*\]', 'table', definition)

        start_bracket = definition.find('(')
        end_bracket = definition.find(')', start_bracket)

        name_start = definition.rfind(' ', 0, start_bracket)
        self.name = definition[name_start + 1:start_bracket]

        returns = definition[definition.startswith('function ') + len('function'):name_start]
        params = definition[start_bracket + 1:end_bracket]
        params = flip_args(params)

        constructor_parameters = []
        definition_parameters = ''
        construct_count = 0
        for param in params:
            if param:
                param = split_careful(param, ' ')
                construct_return = param[0]
                if not construct_return:
                    construct_count += 1
                    construct_return = "var" + str(construct_count)
                for illegal in ('function', 'in'):
                    if construct_return == illegal:
                        construct_return = '_' + illegal
                if len(param) > 1:
                    definition_parameters += f'---@param {construct_return} {" | ".join(param[1:])}\n'
                constructor_parameters.append(construct_return)
        self.arguments = ', '.join(constructor_parameters)

        if returns:
            returns = split_careful(returns, ' ')
            d_returns = returns.copy()
            for idx, return_type in enumerate(returns):
                for illegal in ('function', 'in'):
                    if return_type == illegal:
                        return_type = '_' + illegal
                returns[idx] = get_default_value(return_type)
                d_returns[idx] = get_raw_default_value(return_type)

            definition_returns = f'---@return {",".join(d_returns)}\n' if d_returns else ''
        else:
            definition_returns = ''
            d_returns = ''
            returns = ''

        self.raw_return_value = ",".join(d_returns)
        self.return_value = ",".join(returns)

        return_str = '\n\treturn '
        self.definition = f'{definition_parameters}{definition_returns}function {namespace + ":" if namespace else ""}{self.name}({self.arguments}){return_str if returns else ""}{self.return_value}\nend\n\n'

    def parse_remarks(self, remarks):
        """ Parse a set of remarks from documentation """
        remarks = [remark.strip() for remark in remarks if remark.strip()]
        self.remarks = '--- @callback\n' if self.callback else ''

        parse_parameters = False
        parse_return = False
        parse_definition = True

        iterator = iter(remarks)
        remark = next(iterator, None)
        while remark is not None:
            if remark and not parse_return and not parse_parameters and not parse_definition:
                self.remarks += f'--- {remark}\n'
                parse_definition = True
            elif remark == 'Returns' or remark == 'Expected return values':
                parse_parameters = False
                parse_return = True
            elif remark == 'Parameters':
                parse_parameters = True
            elif parse_return:
                if remark.strip().lower() in ('nothing', 'none', 'void'):
                    # Void function — drop the @return annotation entirely.
                    self.definition = re.sub(r'---@return [^\n]*\n', '', self.definition, count=1)
                else:
                    self.definition = re.sub(
                        r'---@return (.*)\n',
                        lambda m: f'---@return {m.group(1)} @{remark}\n',
                        self.definition, count=1)
                parse_return = False
            elif parse_parameters:
                if remark in self.definition:
                    comment = next(iterator, None)
                    # Precisely target the `---@param <name> <type>` line (the old
                    # loose match could hit a substring of another param), attach
                    # the description, and refine an `any` type from that text.
                    def _sub_param(m):
                        ptype = refine_param_type(remark, m.group(2), comment)
                        opt = '?' if is_optional_param(ptype, comment) else ''
                        return f'---@param {remark}{opt} {ptype}{m.group(3)} @{comment}\n'

                    self.definition = re.sub(
                        r'(---@param ' + re.escape(remark) + r' )(\S+)([^\n]*)\n',
                        _sub_param,
                        self.definition, count=1)
            else:
                self.remarks += f'--- {remark}\n'

            remark = next(iterator, None)


@dataclass
class NamespaceDefinition:
    """ Collection of functions and properties under a single namespace """
    namespace: str
    functions: map
    properties: map
    enums: map

    def merge(self, functions, properties, enums):
        """ Merge new namespace with existing namespace """
        for k, v in functions.items():
            if k not in self.functions:
                self.functions[k] = v
            else:
                self.functions[k] += v

        for k, v in properties.items():
            if k not in self.properties:
                self.properties[k] = v
            else:
                self.properties[k] += v

        for k, v in enums.items():
            assert (k not in self.enums)
            self.enums[k] = v

    def write(self):
        """ Write a single namespace to file """
        filename = (to_snake_case(self.namespace) if self.namespace else 'globals') + '.lua'

        constructor = None

        if self.functions and self.namespace:
            constructor = self.functions[self.namespace][0]
            del self.functions[self.namespace]

        functions = sorted(list(self.functions.values()))
        properties = sorted(self.properties.values())

        with open(STUBS_DIR / filename, 'w') as writer:
            if self.enums:
                for enum, values in self.enums.items():
                    # Field-typed enum: names are statically analyzable as
                    # integers, without fabricating positional numeric values
                    # (the docs don't expose the real engine values).
                    writer.write(f'---@class {enum}\n')
                    for value in values:
                        writer.write(f'---@field {value} integer\n')
                    writer.write(f'{enum} = {{}}\n\n')

            if self.namespace is not None:
                # Methods and fields live on a prefixed local table (e.g.
                # `local _Entity = {}`) tied to the public type via ---@class.
                # The engine constructor keeps the real global name and returns
                # that type. This avoids the global being reassigned from a
                # table to a function (which would orphan every method).
                prefix = '_' + self.namespace

                # Field-annotated class: every property is statically typed via
                # ---@field, instead of a runtime value + trailing comment.
                writer.write(f'---@class {self.namespace}\n')
                for overloads in properties:
                    p = overloads[0]
                    ftype = get_raw_default_value(p.type) or 'any'
                    note = p.remark.strip()
                    note = f'  @{note}' if note else ''
                    writer.write(f'---@field {p.name} {ftype}{note}\n')
                writer.write(f'local {prefix} = {{}}\n\n')

                # Constructor: global function returning an instance of the type.
                if constructor is not None:
                    writer.write(
                        f'---@return {self.namespace}\n'
                        + constructor.definition.replace(')\nend', ')\n\treturn ' + prefix + '\nend'))

                # Member functions attach to the local, so EmmyLua links them to
                # the type rather than to the (now function-valued) global name.
                for function_overloads in functions:
                    for function in function_overloads:
                        writer.write(function.remarks)
                        writer.write(
                            function.definition.replace(f'function {self.namespace}:', f'function {prefix}:', 1))
            else:
                for function_overloads in functions:
                    for function in function_overloads:
                        writer.write(function.remarks)
                        writer.write(function.definition)


class StubGenerator:
    """ Program class """

    def __init__(self, html_dir):
        html_dir = Path(html_dir)
        if not html_dir.exists():
            raise StubGeneratorError(f'Documentation directory does not exist: {html_dir}')

        self.namespaces = {}
        self.files = [file for file in html_dir.glob('*.html')]

        if not self.files:
            raise StubGeneratorError(f'No HTML files found in: {html_dir}')

    def generate_stub(self, file):
        """ Generates a stub lua file based on html documentation """
        if not file.suffix == '.html':
            raise StubGeneratorError('parse_definitions expected an HTML file')

        text = file.read_text()

        soup = BeautifulSoup(text, 'html.parser')
        if soup.title.string.find('Predefined') != -1:
            return
        code_containers = soup.findAll("div", {"class": "codecontainer"})

        lines = []
        for code in code_containers[1:]:
            text = str(code)
            text = re.sub(r'\<[^\<]*\>', '', text).strip()

            text = text.replace('&amp;lt', '<')
            text = text.replace('&lt;', '<')
            text = text.replace('&gt;', '>')
            text = text.replace('&amp;', '')

            text = text.replace('unsigned int', 'unsigned')
            if text:
                lines.append(text)

        properties = {}
        functions = {}
        enums = {}

        namespace = None

        found_callbacks_in_title = file.name.find(' Callbacks')
        if found_callbacks_in_title != -1:
            namespace = file.name[:found_callbacks_in_title].split()[0]

        for line in lines:
            if line.startswith('--'):
                continue

            if not properties and line.startswith('property '):

                if namespace is None and functions:
                    namespace = next(iter(functions.keys()))

                lines = [line.strip() for line in line.split('\n') if line.strip().startswith('property ')]
                for idx, p in enumerate(lines):
                    parsed = ParsedProperty()
                    parsed.parse_property(p)
                    properties[parsed.name] = [parsed]

            elif line.startswith('function ') or line.startswith('callback '):
                function = [line.strip() for line in line.split('\n') if line.strip()]
                parsed = ParsedFunction()
                parsed.parse_definition(function[0], namespace)
                parsed.parse_remarks(function[1:])

                if namespace is None and not functions and parsed.name[0].upper() == parsed.name[0]:
                    namespace = parsed.name

                functions[parsed.name] = [parsed]
            elif line.startswith('enum '):
                values = [line.strip() for line in line.split('\n') if line.strip()]
                name = values[0].split()[-1]
                enums[name] = [value for value in values if ' ' not in value]
                DEFAULT_VALUES_BY_TYPE[name] = f'{name}.{enums[name][0]}'
            else:
                pass

        if namespace not in self.namespaces:
            self.namespaces[namespace] = NamespaceDefinition(namespace, functions, properties, enums)
        else:
            self.namespaces[namespace].merge(functions, properties, enums)

        return

    def write_all(self):
        """ Write all namespace definitions to stub files """
        for definition in self.namespaces.values():
            definition.write()

    def write_forward_declarations(self):
        """ Declare every referenced-but-undeclared type so EmmyLua can resolve
            it. Reads back the generated stubs, collects declared classes/aliases
            and referenced type tokens, and emits the difference into
            _Forward.lua (classes) and aliases for integer-handle types. """
        declared = set()
        referenced = set()

        type_line = re.compile(r'^---@(param|return|field)\s+(.*)')
        ident = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')

        for path in STUBS_DIR.glob('*.lua'):
            for line in path.read_text(encoding='utf-8').splitlines():
                decl = re.match(r'^---@(class|alias)\s+([A-Za-z_][A-Za-z0-9_]*)', line)
                if decl:
                    declared.add(decl.group(2))
                    continue
                m = type_line.match(line)
                if not m:
                    continue
                kind, rest = m.group(1), m.group(2)
                if kind in ('param', 'field'):
                    parts = rest.split(None, 1)        # drop the field/param name
                    rest = parts[1] if len(parts) > 1 else ''
                rest = rest.split('@', 1)[0]           # drop trailing description
                for tok in ident.findall(rest):
                    referenced.add(tok)

        missing = sorted(
            tok for tok in referenced - declared - PRIMITIVES
            if tok in MATH_TYPES or (tok[:1].isupper())
        )

        if not missing:
            return

        with open(STUBS_DIR / '_forward.lua', 'w', encoding='utf-8') as writer:
            writer.write('-- Forward declarations for types referenced in the\n')
            writer.write('-- generated stubs that have no dedicated doc page.\n\n')
            for tok in missing:
                if tok in TYPE_ALIASES:
                    writer.write(f'---@alias {tok} {TYPE_ALIASES[tok]}\n')
                else:
                    writer.write(f'---@class {tok}\n{tok} = {{}}\n\n')

    @staticmethod
    def write_extras():
        """ Emit hand-maintained engine globals that have no documentation page,
            so the generated set is self-contained. """
        (STUBS_DIR / '_extras.lua').write_text(EXTRAS_LUA, encoding='utf-8')

    def run(self):
        """ Program entrypoint """
        print('Processing...')
        for file in self.files:

            if file.name == 'index.html':
                continue

            if file.name == 'FactionDatabaseFunctions.html':
                continue

            self.generate_stub(file)

        self.write_all()
        self.write_extras()
        self.write_forward_declarations()
        print('Finished.')


def resolve_docs_dir(arg_docs):
    """ Resolve the documentation directory from (in order): the CLI argument,
        $AVORION_DOCS_DIR, or $AVORION_DATA_DIR/../documentation. """
    if arg_docs:
        return Path(arg_docs)

    env_docs = os.environ.get('AVORION_DOCS_DIR')
    if env_docs:
        return Path(env_docs)

    data_dir = os.environ.get('AVORION_DATA_DIR')
    if data_dir:
        return Path(data_dir).parent / 'documentation'

    raise StubGeneratorError(
        'No documentation path. Pass it as an argument, or set $AVORION_DOCS_DIR '
        'or $AVORION_DATA_DIR (docs are read from <AVORION_DATA_DIR>/../documentation).')


def main(argv=None):
    parser = argparse.ArgumentParser(
        description='Generate EmmyLua stubs from the Avorion API documentation.')
    parser.add_argument('docs', nargs='?',
                        help='Path to the Avorion documentation directory (the folder of *.html '
                             'files). Defaults to $AVORION_DOCS_DIR, then $AVORION_DATA_DIR/../documentation.')
    parser.add_argument('out', nargs='?', default='stubs/generated',
                        help='Output directory for generated stubs (default: stubs/generated).')
    parser.add_argument('--docs', dest='docs_opt', help='Alias for the docs argument.')
    parser.add_argument('--out', dest='out_opt', help='Alias for the out argument.')
    args = parser.parse_args(argv)

    global STUBS_DIR
    try:
        docs_dir = resolve_docs_dir(args.docs_opt or args.docs)
        STUBS_DIR = Path(args.out_opt or args.out)
        STUBS_DIR.mkdir(parents=True, exist_ok=True)

        print(f'Docs:   {docs_dir}')
        print(f'Output: {STUBS_DIR}')
        StubGenerator(docs_dir).run()
    except StubGeneratorError as err:
        print(f'error: {err}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())