import 'package:di/di.dart';
import 'package:angular/parser_library.dart';

class Code {
  String _exp;
  String _returnOnly;
  Function assign;
  Code(this._exp, [this.assign]);

  Code.returnOnly(this._returnOnly);

  returnExp() => _returnOnly != null ? _returnOnly : "return $exp;";

  get exp {
    if (_exp == null) { throw "Can not be used in an expression"; }
    return _exp;
  }
  get assignable => assign != null;
}

escape(String s) => s.replaceAll('\'', '\\\'').replaceAll(r'$', r'\$');

var LAST_PATH_PART = new RegExp(r'(.*)\.(.*)');

// From https://www.dartlang.org/docs/spec/latest/dart-language-specification.html#h.huusvrzea3q
var RESERVED_DART_KEYWORDS = [
    "assert", "break", "case", "catch", "class", "const", "continue",
    "default", "do", "else", "enum", "extends", "false", "final",
    "finally", "for", "if", "in", "is", "new", "null", "rethrow",
    "return", "super", "switch", "this", "throw", "true", "try",
    "var", "void", "while", "with"];
isReserved(String key) => RESERVED_DART_KEYWORDS.contains(key);

class GetterSetterGenerator {
  String functions = "// GETTER AND SETTER FUNCTIONS\n\n";
  var _keyToGetterFnName = {};
  var _keyToSetterFnName = {};
  var nextUid = 0;

  fieldGetter(String field, String obj) {
    var eKey = escape(field);

    var returnValue = isReserved(field) ? "null /* $field is reserved */" : "$obj.$field";

    return """
  if ($obj is Map) {
    if ($obj.containsKey('$eKey')) {
      return $obj['$eKey'];
    }
    return null;
  }
  return $returnValue;
}
""";
  }

  fieldSetter(String field, String obj) {
    var eKey = escape(field);

    var maybeField = isReserved(field) ? "/* $field is reserved */" : """
  $obj.$field = value;
  return value;
    """;

    return """
  if ($obj is Map) {
    $obj['$eKey'] = value;
    return value;
  }
  $maybeField
}
""";
  }

  _accessor(String key, fieldAccessor, isGetter) {
    var uid = nextUid++;
    var fnName = isGetter ? "_getter_$uid" : "_setter_$uid";

    var f = "$fnName(scope, locals${!isGetter ? ", value" : ""}) { // for $key\n";
    var obj = "scope";

    var field = key;
    var pathSplit = LAST_PATH_PART.firstMatch(key);
    if (pathSplit != null) {
      var prefixFn = call(pathSplit[1]);
      field = pathSplit[2];
      f += """  var prefix = $prefixFn(scope, locals);
  if (prefix == null) return null;
""";
      obj = "prefix";
    }
    f += fieldAccessor(field, obj);

    functions += f;

    return fnName;
  }

  call(String key) {
    if (_keyToGetterFnName.containsKey(key)) {
      return _keyToGetterFnName[key];
    }

    var fnName = _accessor(key, fieldGetter, true);

    _keyToGetterFnName[key] = fnName;
    return fnName;
  }

  setter(String key) {
    if (_keyToSetterFnName.containsKey(key)) {
      return _keyToSetterFnName[key];
    }

    var uid = nextUid++;
    var fnName = "_setter_$uid";

    var f = "$fnName(scope, locals, value) { // for $key\n";
    var obj = "scope";

    var field = key;
    var pathSplit = LAST_PATH_PART.firstMatch(key);
    if (pathSplit != null) {
      var prefixFn = call(pathSplit[1]);
      var prefixSetter = setter(pathSplit[1]);
      field = pathSplit[2];
      f += """  var prefix = $prefixFn(scope, locals);
  if (prefix == null) {
    prefix = {};
    $prefixSetter(scope, locals, prefix);
  }
""";
      obj = "prefix";
    }

    f += fieldSetter(field, obj);
    functions += f;

    _keyToSetterFnName[key] = fnName;
    return fnName;
  }
}


class CodeExpressionFactory {
  GetterSetterGenerator _getterGen;

  CodeExpressionFactory(GetterSetterGenerator this._getterGen);
  _op(fn) => fn;

  binaryFn(left, fn, right) {
    if (fn == '+') {
      return new Code("autoConvertAdd(${left.exp}, ${right.exp})");
    }
    return new Code("${left.exp} ${_op(fn)} ${right.exp}");
  }

  unaryFn(fn, right) => new Code("${_op(fn)}${right.exp}");

  assignment(left, right, evalError) {
    return left.assign(right);
  }

  multipleStatements(statements) {
    var code = "var ret, last;\n";
    code += statements.map((s) =>
        "last = ${s.exp};\nif (last != null) { ret = last; }\n").join('\n');
    code += "return ret;\n";
    return new Code.returnOnly(code);
  }

  functionCall(Code fn, fnName, List<Code> argsFn, evalError) {
    return new Code("${fn.exp}(${argsFn.map((a) => a.exp).join(', ')})");
  }
  arrayDeclaration(elementFns) {
    return new Code("[${elementFns.map((e) => e.exp).join(', ')}]");
  }
  objectIndex(Code obj, Code indexFn, evalError) {
    var assign = (Code right) {
      return new Code("objectIndexSetField(${obj.exp}, ${indexFn.exp}, ${right.exp}, evalError)");
    };
    return new Code("objectIndexGetField(${obj.exp}, ${indexFn.exp}, evalError)", assign);
  }
  fieldAccess(Code object, field) {
    var getterFnName = _getterGen(field);
    return new Code("$getterFnName/*field:$field*/(${object.exp}, null)");
  }

  object(List keyValues) {
    return new Code(
        "{${keyValues.map((k) => "${_value(k["key"])}: ${k["value"].exp}").join(', ')}}");
  }
  profiled(value, perf, text) => value; // no profiling for now
  fromOperator(op) => new Code(_op(op));

  getterSetter(key) {
    var getterFnName = _getterGen(key);

    var assign = (Code right) {
      var setterFnName = _getterGen.setter(key);
      return new Code("${setterFnName}(scope, locals, ${right.exp})");
    };

    return new Code("$getterFnName/*$key*/(scope, locals)", assign);
  }

  _value(v) => v is String ? "r\'${escape(v)}\'" : v;
  value(v) => new Code(_value(v));
  zero() => new Code(0);
}

class ParserGenerator {
  Parser _parser;
  NestedPrinter _p;
  List<String> _expressions;
  GetterSetterGenerator _getters;

  ParserGenerator(Parser this._parser, NestedPrinter this._p,
                  GetterSetterGenerator this._getters);

  generateParser(List<String> expressions) {
    _expressions = expressions;
    _printParser();
    _printTestMain();
  }

  String generateDart(String expression) {
    var tokens = _lexer(expression);
  }

  _printParser() {
    _printFunctions();
    _p('class GeneratedParser implements Parser {');
    _p.indent();
    _printParserClass();
    _p.dedent();
    _p('}');
    _p(_getters.functions);
  }

  _printFunctions() {
    _p('var _FUNCTIONS = {');
    _p.indent();
    _expressions.forEach((exp) => _printFunction(exp));
    _p.dedent();
    _p('};');
  //'1': new Expression((scope, [locals]) => 1)
  }

  _printFunction(exp) {
    _p('\'${escape(exp)}\': new Expression((scope, [locals]) {');
    _p.indent();
    _functionBody(exp);
    _p.dedent();
    _p('}),');
  }

  _functionBody(exp) {
    var codeExpression;

    _p('evalError(s, [stack]) => parserEvalError(s, \'${escape(exp)}\', stack);');
    try {
      codeExpression = _parser(exp);
    } catch (e) {
      if ("$e".contains('Parser Error') ||
          "$e".contains('Unexpected end of expression')) {
        codeExpression = new Code.returnOnly("throw r'$e';");
      } else {
        rethrow;
      }
    }
    _p(codeExpression.returnExp());
  }

  _printParserClass() {
    _p(r"""GeneratedParser(Profiler x);
call(String t) {
  if (!_FUNCTIONS.containsKey(t)) {
    dump(":XNAY:$t:XNAY:");
    //dump("Expression $t is not supported be GeneratedParser");
  }

  return _FUNCTIONS[t];
}""");
  }

  _printTestMain() {
    _p("""
    genEvalError(msg) { throw msg; }

    generatedMain() {
  describe(\'generated parser\', () {
    beforeEach(module((AngularModule module) {
      module.type(Parser, GeneratedParser);
    }));
    main();
  });
}""");
  }
}

class NestedPrinter {
  String indentString = '';
  call(String s) {
    if (s[0] == '\n') s.replaceFirst('\n', '');
    var lines = s.split('\n');
    lines.forEach((l) { _oneLine(l); });
  }

  _oneLine(String s) {
    print("$indentString$s");
  }

  indent() {
    indentString += '  ';
  }
  dedent() {
    indentString = indentString.replaceFirst('  ', '');
  }
}

main() {
  Module module = new Module()
    ..type(ExpressionFactory, CodeExpressionFactory);

  Injector injector = new Injector([module]);

  // List generated using:
  // node node_modules/karma/bin/karma run | grep -Eo ":XNAY:.*:XNAY:" | sed -e 's/:XNAY://g' | sed -e "s/^/'/" | sed -e "s/$/',/" | sort | uniq > missing_expressions
  injector.get(ParserGenerator).generateParser([
      "1", "-1", "+1",
      "!true",
      "3*4/2%5", "3+6-2",
  "2<3", "2>3", "2<=2", "2>=2",
  "2==3", "2!=3",
  "true&&true", "true&&false",
      "true||true", "true||false", "false||false",
"'str ' + 4", "4 + ' str'", "4 + 4", "4 + 4 + ' str'",
"'str ' + 4 + 4",
      "a", "b.c" , "x.y.z",
      'ident.id(6)', 'ident.doubleId(4,5)',
      "a.b.c.d.e.f.g.h.i.j.k.l.m.n",
      'b', 'a.x', 'a.b.c.d',
      "(1+2)*3",
      "a=12", "arr[c=1]", "x.y.z=123;",
      "a=123; b=234",
      "constN()", "const",
      "add(1,2)",
      "getter()()",
      "obj.elementAt(0)",
      "this['a'].b",
      "[]",
      "[1, 2]",
      "[1][0]",
      "[[1]][0][0]",
      "[].length",
"[1, 2].length",
      "{}",
"{a:'b'}",
    "{'a':'b'}",
"{\"a\":'b'}",
      "{false:'WC', true:'CC'}[false]",
')',
'[{}]',
'0&&2',
'1%2',
'1 + 2.5',
'1+undefined',
'4()',
'4|a',
'5=4',
'6[3]',
'{a',
'a[1]=2',
'a=1;b=3;a+b',
'a.b',
'a(b',
'\'a\' + \'b c\'',
'a().name',
'a[x()]()',
'boo',
'[].count(',
'doesNotExist()',
'false',
'false && run()',
'!false || true',
'foo()',
'\$id',
'items[1] = "abc"',
'items[1].name',
'list[3] = 2',
'map["square"] = 6',
'method',
'method()',
'notAFn()',
'notmixed',
'null',
'null[3]',
'obj[0].name=1',
'obj.field = 1',
'obj.field.key = 4',
'obj.integer = "hello"',
'obj.map.mapKey = 3',
'obj.nested.field = 1',
'obj.overload = 7',
'obj.setter = 2',
'str',
'str="bob"',
'suffix = "!"',
'taxRate / 100 * subTotal',
'true',
'true || run()',
'undefined',

';;1;;',
'1==1',
'!(11 == 10)',
'1 + -2.5',
'[{a',
'{a',
'array[5=4]',
'map.null',
'\$root',
'subTotal * taxRate / 100',
'!!true',

      '1!=2',
'1+2*3/4',
'[{a',
'{a',
'\$parent',
'{true',

'0--1+1.5',
'1<2',
'[{a',
'{a',
'{true',
'1<=1',

      '1>2',
'{a:\'-\'}',
'{a:a}',
'[{a:[]}, {b:1}]',
'{true:"a", false:"b"}[!!true]',

      '2>=1',
      'true==2<3',
'6[3]=2',

      'map.dot = 7'

  ]);
}
