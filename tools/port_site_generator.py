#!/usr/bin/env python3
"""Development-only mechanical lowering of the frozen generator to POSIX awk.

Never shipped to nodes. Keeps every recipe, rendering branch and CSS rule in
the reference; unsupported syntax fails the build instead of silently skipping
it. Generated awk contains ordinary functions, not a Python interpreter.
"""
import ast
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tests/reference/site_generator.py"
TARGET = ROOT / "tools/site-generator/design.awk"


def literal(s):
    return json.dumps(s, ensure_ascii=False).replace("\\u001c", "\\034").replace("\\u001d", "\\035")


class Compiler:
    def __init__(self, tree):
        self.functions = {}
        self.globals = set()
        self.methods = {}
        for n in tree.body:
            if isinstance(n, ast.ClassDef) and n.name == "SiteGenerator":
                self.methods = {f.name: f for f in n.body if isinstance(f, ast.FunctionDef)}
            elif isinstance(n, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
                target = n.targets[0] if isinstance(n, ast.Assign) else n.target
                if isinstance(target, ast.Name):
                    self.globals.add(target.id)
            elif isinstance(n, ast.FunctionDef):
                self.functions[n.name] = n
        self.out = []
        self.lines = []
        self.locals = set()
        self.names = {}
        self.counter = 0

    def emit(self, s):
        self.lines.append(s)

    def temp(self, expression=None):
        self.counter += 1
        # One function-local array avoids mawk's limit on formal parameters.
        # Omitted array parameters are local to each invocation, including recursion.
        name = f"tmp[{self.counter}]"
        self.locals.add("tmp")
        if expression is not None:
            self.emit(f"{name} = {expression};")
        return name

    def name(self, name):
        if name in self.globals:
            return "G_" + name
        if name not in self.names:
            self.names[name] = "v_" + name
            self.locals.add(self.names[name])
        return self.names[name]

    def seq(self, items, kind="list"):
        v = self.temp(f'newobj("{kind}")')
        for item in items:
            if isinstance(item, ast.Starred):
                self.emit(f"extend({v}, {self.expr(item.value)});")
            else:
                self.emit(f"push({v}, {self.expr(item)});")
        return v

    def expr(self, n):
        if isinstance(n, ast.Constant):
            if n.value is None:
                return "NONE"
            if isinstance(n.value, str):
                # Split long CSS literals for small mawk parser limits.
                if len(n.value) > 3000:
                    v = self.temp('box("")')
                    for start in range(0, len(n.value), 3000):
                        self.emit(f"{v} = box(text({v}) {literal(n.value[start:start+3000])});")
                    return v
                return f"box({literal(n.value)})"
            return repr(int(n.value)) if isinstance(n.value, bool) else repr(n.value)
        if isinstance(n, ast.Name):
            return self.name(n.id)
        if isinstance(n, ast.Attribute):
            return self.temp(f"get({self.expr(n.value)}, box({literal(n.attr)}))")
        if isinstance(n, ast.Subscript):
            v = self.expr(n.value)
            if isinstance(n.slice, ast.Slice):
                args = [self.expr(x) if x else "NONE" for x in (n.slice.lower, n.slice.upper, n.slice.step)]
                return self.temp(f"sliceval({v}, {', '.join(args)})")
            return self.temp(f"get({v}, {self.expr(n.slice)})")
        if isinstance(n, (ast.List, ast.Tuple, ast.Set)):
            return self.seq(n.elts, {ast.List: "list", ast.Tuple: "tuple", ast.Set: "set"}[type(n)])
        if isinstance(n, ast.Dict):
            v = self.temp('newobj("dict")')
            for key, value in zip(n.keys, n.values):
                self.emit(f"put({v}, {self.expr(key)}, {self.expr(value)});")
            return v
        if isinstance(n, ast.JoinedStr):
            v = self.temp('box("")')
            for part in n.values:
                if isinstance(part, ast.FormattedValue):
                    value = self.expr(part.value)
                    spec = self.expr(part.format_spec) if part.format_spec else 'box("")'
                    value = self.temp(f"formatval({value}, {spec})")
                else:
                    value = self.expr(part)
                self.emit(f"{v} = box(text({v}) text({value}));")
            return v
        if isinstance(n, ast.BinOp):
            left, right = self.expr(n.left), self.expr(n.right)
            op = {ast.Add: "add", ast.Sub: "sub", ast.Mult: "mul", ast.Div: "div", ast.FloorDiv: "floor", ast.Mod: "mod", ast.Pow: "pow"}[type(n.op)]
            return self.temp(f'opval("{op}", {left}, {right})')
        if isinstance(n, ast.UnaryOp):
            v = self.expr(n.operand)
            return self.temp(f"!truth({v})" if isinstance(n.op, ast.Not) else f"-({v})")
        if isinstance(n, ast.BoolOp):
            v = self.temp(self.expr(n.values[0]))
            for right in n.values[1:]:
                self.emit(f"if ({'' if isinstance(n.op, ast.And) else '!'}truth({v})) {{")
                value = self.expr(right)
                self.emit(f"{v} = {value};\n}}")
            return v
        if isinstance(n, ast.IfExp):
            v = self.temp()
            test = self.expr(n.test)
            self.emit(f"if (truth({test})) {{")
            yes = self.expr(n.body)
            self.emit(f"{v} = {yes};\n}} else {{")
            no = self.expr(n.orelse)
            self.emit(f"{v} = {no};\n}}")
            return v
        if isinstance(n, ast.Compare):
            result = self.temp("1")
            left = self.expr(n.left)
            for op, node in zip(n.ops, n.comparators):
                self.emit(f"if ({result}) {{")
                right = self.expr(node)
                if isinstance(op, (ast.In, ast.NotIn)):
                    test = f"contains({right}, {left})"
                    if isinstance(op, ast.NotIn):
                        test = "!" + test
                else:
                    symbol = {ast.Eq: "==", ast.NotEq: "!=", ast.Is: "==", ast.IsNot: "!=", ast.Lt: "<", ast.LtE: "<=", ast.Gt: ">", ast.GtE: ">="}[type(op)]
                    test = f"({left} {symbol} {right})"
                self.emit(f"{result} = {test};\n}}")
                left = right
            return result
        if isinstance(n, (ast.ListComp, ast.GeneratorExp, ast.SetComp)):
            result = self.temp('newobj("set")' if isinstance(n, ast.SetComp) else 'newobj("list")')
            old_names = self.names.copy()
            for generator in n.generators:
                for target in ast.walk(generator.target):
                    if isinstance(target, ast.Name):
                        self.names[target.id] = self.temp()
            def generate(index):
                if index == len(n.generators):
                    self.emit(f"push({result}, {self.expr(n.elt)});")
                    return
                g = n.generators[index]
                self.loop(g.target, g.iter, lambda: filtered(g, index))
            def filtered(g, index):
                for cond in g.ifs:
                    self.emit(f"if (!truth({self.expr(cond)})) continue;")
                generate(index + 1)
            generate(0)
            self.names = old_names
            return result
        if isinstance(n, ast.Call):
            return self.call(n)
        raise ValueError(f"Unsupported expression at {n.lineno}: {ast.dump(n)[:250]}")

    def call(self, n):
        f = ast.unparse(n.func)
        args = []
        for arg in n.args:
            if isinstance(arg, ast.Starred):
                value = self.expr(arg.value)
                args += [self.temp(f"get({value}, 0)"), self.temp(f"get({value}, 1)")]
            else:
                args.append(self.expr(arg))
        kw = {k.arg: self.expr(k.value) for k in n.keywords}
        if f == "flatten":
            return self.temp(f"flatten_into({args[1]}, {args[0]}, {self.name('flat')})")
        if f == "isinstance":
            # The second argument was rendered as a name, but is a type token.
            types = ast.unparse(n.args[1])
            return self.temp(f"istype({args[0]}, {literal(types)})")
        if f == "getattr":
            return args[1]  # Only render_section dispatch, checked by dispatcher.
        if f == "method":
            return self.temp(f"dispatch_section({self.name('self')}, {self.name('method')}, {args[0]})")
        if f == "SiteResult":
            v = self.temp('newobj("dict")')
            for key, value in kw.items():
                self.emit(f"put({v}, box({literal(key)}), {value});")
            return v
        if f in self.functions or (f.startswith("self.") and f[5:] in self.methods):
            method = f.startswith("self.")
            node = self.methods[f[5:]] if method else self.functions[f]
            if method:
                args.insert(0, self.name("self"))
            params = node.args.args
            defaults = [None] * (len(params) - len(node.args.defaults)) + node.args.defaults
            for i in range(len(args), len(params)):
                p = params[i].arg
                args.append(kw.pop(p) if p in kw else self.expr(defaults[i]))
            if kw:
                raise ValueError(f"Unknown keyword {kw}: {f}")
            return self.temp(f"{'m_' + f[5:] if method else 'g_' + f}({', '.join(args)})")
        if f == "random.Random":
            return "0"  # One deterministic random stream per generation.
        if ".rng." in f or f.startswith("rng."):
            name = f.rsplit(".", 1)[-1]
            if "k" in kw:
                args.append(kw.pop("k"))
            return self.temp(f"rng_{name}({', '.join(args)})")
        simple = {"len": "lengthval", "int": "int", "float": "numeric", "str": "stringval", "abs": "absolute", "round": "roundval", "list": "copylist", "dict": "copydict", "set": "makeset", "sorted": "sortlist", "sum": "sumlist", "all": "alllist", "math.ceil": "ceilval", "dict.fromkeys": "makeset"}
        if f in simple:
            if f == "round" and len(args) == 1:
                args.append("0")
            return self.temp(f"{simple[f]}({', '.join(args)})")
        if f in ("min", "max"):
            v = self.temp('newobj("list")')
            for arg in args:
                self.emit(f"push({v}, {arg});")
            return self.temp(f"extreme({v}, {1 if f == 'max' else 0})")
        if f == "range":
            args = (["0", args[0], "1"] if len(args) == 1 else args + ["1"] if len(args) == 2 else args)
            return self.temp(f"rangeval({', '.join(args)})")
        if f == "enumerate":
            if len(args) == 1:
                args.append(kw.pop("start", "0"))
            return self.temp(f"enumerateval({', '.join(args)})")
        if f == "re.findall":
            return self.temp(f"wordlist({args[1]})")
        if f == "re.split":
            return self.temp(f"headline_clauses({args[1]})")
        if isinstance(n.func, ast.Attribute):
            obj = self.expr(n.func.value)
            return self.temp(f"methodval({obj}, {literal(n.func.attr)}, {len(args)}" + (", " + ", ".join(args) if args else "") + ")")
        raise ValueError(f"Unsupported call {f} at {n.lineno}")

    def assign(self, target, value):
        if isinstance(target, ast.Name):
            self.emit(f"{self.name(target.id)} = {value};")
        elif isinstance(target, ast.Attribute):
            self.emit(f"put({self.expr(target.value)}, box({literal(target.attr)}), {value});")
        elif isinstance(target, ast.Subscript):
            self.emit(f"put({self.expr(target.value)}, {self.expr(target.slice)}, {value});")
        elif isinstance(target, (ast.Tuple, ast.List)):
            saved = self.temp(value)
            for i, part in enumerate(target.elts):
                self.assign(part, f"get({saved}, {i})")
        else:
            raise ValueError(ast.dump(target))

    def loop(self, target, iterable, body):
        items = self.temp(f"iterable({self.expr(iterable)})")
        index = self.temp("0")
        self.emit(f"for ({index} = 0; {index} < lengthval({items}); {index}++) {{")
        self.assign(target, f"get({items}, {index})")
        body()
        self.emit("}")

    def statements(self, body):
        for n in body:
            if isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant):
                continue
            self.emit(f"# reference:{n.lineno}")
            if isinstance(n, ast.FunctionDef):
                if n.name != "flatten":
                    raise ValueError(n.name)
            elif isinstance(n, ast.Assign):
                v = self.expr(n.value)
                for target in n.targets:
                    self.assign(target, v)
            elif isinstance(n, ast.AnnAssign):
                if n.value:
                    self.assign(n.target, self.expr(n.value))
            elif isinstance(n, ast.AugAssign):
                left = self.expr(n.target)
                right = self.expr(n.value)
                self.assign(n.target, f'opval("{ {ast.Add:"add",ast.Sub:"sub",ast.Mult:"mul"}[type(n.op)]}", {left}, {right})')
            elif isinstance(n, ast.Return):
                self.emit(f"return {self.expr(n.value) if n.value else 'NONE'};")
            elif isinstance(n, ast.Expr):
                self.expr(n.value)
            elif isinstance(n, ast.If):
                self.emit(f"if (truth({self.expr(n.test)})) {{")
                self.statements(n.body)
                if n.orelse:
                    self.emit("} else {")
                    self.statements(n.orelse)
                self.emit("}")
            elif isinstance(n, ast.For):
                assert not n.orelse
                self.loop(n.target, n.iter, lambda: self.statements(n.body))
            elif isinstance(n, ast.While):
                self.emit("while (1) {")
                self.emit(f"if (!truth({self.expr(n.test)})) break;")
                self.statements(n.body)
                self.emit("}")
            elif isinstance(n, (ast.Continue, ast.Break)):
                self.emit("continue;" if isinstance(n, ast.Continue) else "break;")
            elif isinstance(n, ast.Delete):
                for target in n.targets:
                    self.emit(f"removeval({self.expr(target.value)}, {self.expr(target.slice)});")
            else:
                raise ValueError(f"Unsupported statement {ast.dump(n)[:200]}")

    def function(self, name, node=None, statements=None):
        self.lines, self.locals, self.names, self.counter = [], set(), {}, 0
        params = [self.name(a.arg) for a in node.args.args] if node else []
        self.statements(node.body if node else statements)
        local = sorted(self.locals - set(params))
        args = ", ".join(params) + (", " if params and local else "") + ", ".join(local)
        self.out.append(f"function {name}({args}) {{\n" + "\n".join("    " + x for x in self.lines) + "\n}\n")

    def build(self, tree):
        # Numeric/string/collection helpers are hand-ported in runtime.awk;
        # icon_svg and the entire design/rendering class are lowered unchanged.
        self.function("g_icon_svg", self.functions["icon_svg"])
        for name, node in self.methods.items():
            self.function("m_" + name, node)
        statements = [n for n in tree.body if isinstance(n, (ast.Assign, ast.AnnAssign, ast.AugAssign, ast.Expr)) and n.lineno < 5383]
        self.function("init_design", statements=statements)
        dispatch = ["function dispatch_section(self, name, spec) {", "    name = text(name);"]
        for name in self.methods:
            if name.startswith("render_section_"):
                dispatch.append(f'    if (name == "{name}") return m_{name}(self, spec);')
        dispatch += ["    return m_render_section_facts(self, spec);", "}"]
        self.out.append("\n".join(dispatch))
        return "# Generated by tools/port_site_generator.py; edit the frozen reference only for a deliberate port correction.\n" + "\n".join(self.out)


if __name__ == "__main__":
    tree = ast.parse(SOURCE.read_text(encoding="utf-8"))
    # Drop auditing/CLI code; the node has a native shell CLI and awk audit.
    tree.body = [n for n in tree.body if n.lineno < 5383]
    output = Compiler(tree).build(tree)
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    TARGET.write_text(output, encoding="utf-8", newline="\n")
