// TODO: TokenStream

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:string_scanner/string_scanner.dart';

import 'environment.dart';
import 'exceptions.dart';
import 'nodes.dart';

typedef TemplateModifier = void Function(Template template);

class Parser {
  static RegExp getOpenReg(String rule, [bool leftStripBlocks = false]) {
    rule = RegExp.escape(rule);
    final strip = leftStripBlocks ? '(^[ \\t]*)$rule\\+|^[ \\t]*$rule|' : '';
    return RegExp('(?:\\s*$rule\\-|$strip$rule\\+?)\\s*', multiLine: true);
  }

  static RegExp getEndReg(String rule, [bool trimBlocks = false]) {
    rule = RegExp.escape(rule);
    final trim = trimBlocks ? '\n?' : '';
    return RegExp('\\s*(?:\\-$rule\\s*|$rule$trim)', multiLine: true);
  }

  Parser(this.environment, String source, {this.path})
      : _scanner = SpanScanner(source, sourceUrl: path),
        commentStartReg = getOpenReg(environment.commentStart, environment.leftStripBlocks),
        commentEndReg = getEndReg(environment.commentEnd, environment.trimBlocks),
        variableStartReg = getOpenReg(environment.variableStart),
        variableEndReg = getEndReg(environment.variableEnd),
        blockStartReg = getOpenReg(environment.blockStart, environment.leftStripBlocks),
        blockEndReg = getEndReg(environment.blockEnd, environment.trimBlocks),
        keywords = <String>{'not', 'and', 'or', 'is', 'if', 'else'};

  final Environment environment;
  final String path;

  final SpanScanner _scanner;

  final RegExp blockStartReg;
  final RegExp blockEndReg;
  final RegExp variableStartReg;
  final RegExp variableEndReg;
  final RegExp commentStartReg;
  final RegExp commentEndReg;

  final Set<String> keywords;

  final List<ExtendsStatement> extendsStatements = <ExtendsStatement>[];
  final List<List<Pattern>> endRulesStack = <List<Pattern>>[];
  final List<String> tagsStack = <String>[];

  RegExp getEndRegFor(String rule, [bool withStart = false]) {
    if (withStart) {
      return RegExp(blockStartReg.pattern + RegExp.escape(rule) + blockEndReg.pattern, multiLine: true);
    }

    return RegExp(RegExp.escape(rule) + blockEndReg.pattern);
  }

  final StreamController<Name> _onParseNameController = StreamController<Name>.broadcast(sync: true);

  Stream<Name> get onParseName => _onParseNameController.stream;

  final List<TemplateModifier> _templateModifiers = <TemplateModifier>[];

  void addTemplateModifier(TemplateModifier modifier) {
    _templateModifiers.add(modifier);
  }

  @alwaysThrows
  void error(String message) {
    throw TemplateSyntaxError(message, path: path, line: _scanner.state.line, column: _scanner.state.column);
  }

  void expect(Pattern pattern, {String name}) {
    if (_scanner.scan(pattern)) return;

    if (name == null) {
      if (pattern is RegExp) {
        final source = pattern.pattern;
        name = '/$source/';
      } else {
        name = pattern.toString().replaceAll('\\', '\\\\').replaceAll('"', '\\"');
        name = '"$name"';
      }
    }

    throw TemplateSyntaxError(
      '$name expected',
      path: path,
      line: _scanner.state.line,
      column: _scanner.state.column,
    );
  }

  bool scan(Pattern pattern) => _scanner.scan(pattern);

  Match get lastMatch => _scanner.lastMatch;

  bool matches(Pattern pattern) => _scanner.matches(pattern);

  bool get isDone => _scanner.isDone;

  Template parse() {
    var body = parseBody();
    var template = Template.parsed(body: body, env: environment, path: path);

    for (var modifier in _templateModifiers) {
      modifier(template);
    }

    return template;
  }

  Node parseBody([List<Pattern> endRules = const <Pattern>[]]) {
    var nodes = subParse(endRules);
    return environment.optimize ? Interpolation.orNode(nodes) : Interpolation(nodes);
  }

  List<Node> subParse(List<Pattern> endRules) {
    var buffer = StringBuffer();
    var body = <Node>[];

    if (endRules.isNotEmpty) endRulesStack.add(endRules);

    void flush() {
      if (buffer.isNotEmpty) {
        body.add(Text('$buffer'));
        buffer.clear();
      }
    }

    try {
      while (!_scanner.isDone) {
        if (_scanner.scan(commentStartReg)) {
          flush();

          while (!_scanner.matches(commentEndReg)) {
            _scanner.readChar();
          }

          expect(commentEndReg);
        } else if (_scanner.scan(variableStartReg)) {
          flush();
          body.add(parseExpression());
          expect(variableEndReg);
        } else if (_scanner.scan(blockStartReg)) {
          // TODO: lstrip: проверка блока перекрывает переменную

          flush();

          if (_scanner.lastMatch.groupCount > 0 && _scanner.lastMatch[0].trimRight().endsWith('+')) {
            var spaces = _scanner.lastMatch[1];

            if (spaces.isNotEmpty) {
              if (body.isNotEmpty && body.last is Text) {
                body.add(Text((body.removeLast() as Text).text + spaces));
              } else {
                body.add(Text(spaces));
              }
            }
          }

          if (endRules.isNotEmpty && testAll(endRules)) return body;
          body.add(parseStatement());
        } else {
          buffer.writeCharCode(_scanner.readChar());
        }
      }

      flush();
    } finally {
      if (endRules.isNotEmpty) endRulesStack.removeLast();
    }

    return body;
  }

  bool testAll(List<Pattern> endRules) {
    for (var rule in endRules) {
      if (_scanner.matches(rule)) return true;
    }

    return false;
  }

  Node parseStatement() {
    expect(nameReg, name: 'statement tag');

    var tagName = _scanner.lastMatch[1];
    var popTag = true;
    tagsStack.add(tagName);

    expect(spaceReg);

    try {
      switch (tagName) {
        case 'extends':
          return parseExtends();
        case 'block':
          return parseBlock();
        case 'include':
          return parseInlcude();
        case 'for':
          return parseFor();
        case 'if':
          return parseIf();
        case 'set':
          return parseSet();
        case 'raw':
          return parseRaw();
        case 'filter':
          return parseFilterBlock();
        default:
      }

      tagsStack.removeLast();
      popTag = false;
      error('uknown tag: $tagName');
    } finally {
      if (popTag) tagsStack.removeLast();
    }
  }

  // TODO: update, check
  ExtendsStatement parseExtends() {
    var path = parsePrimary();

    expect(blockEndReg);

    var extendsStatement = ExtendsStatement(path);

    extendsStatements.add(extendsStatement);

    var state = _scanner.state;

    addTemplateModifier((Template template) {
      var body = template.body;
      Node first;

      if (body is Interpolation) {
        first = body.nodes.first;

        if (body.nodes.sublist(1).any((Node node) => node is ExtendsStatement)) {
          throw TemplateSyntaxError(
            'only one extends statement contains in template',
            path: _scanner.sourceUrl,
            line: state.line,
            column: state.column,
          );
        }

        body.nodes
          ..clear()
          ..add(first);
      }
    });

    return extendsStatement;
  }

  BlockStatement parseBlock() {
    var blockEndReg = getEndRegFor('endblock');

    if (_scanner.matches(this.blockEndReg)) {
      error('block name expected');
    }

    expect(nameReg, name: 'block name');

    var name = _scanner.lastMatch[1];
    var scoped = false;
    var hasSuper = false;

    if (_scanner.scan(spacePlusReg) && _scanner.scan('scoped')) {
      scoped = true;
    }

    expect(this.blockEndReg);

    var subscription = onParseName.listen((Name node) {
      if (node.name == 'super') hasSuper = true;
    });

    var body = parseBody(<Pattern>[blockEndReg]);
    subscription.cancel();

    expect(blockEndReg);

    if (extendsStatements.isNotEmpty) {
      var block = ExtendedBlockStatement(name, path, body, scoped: scoped, hasSuper: hasSuper);

      for (var extendsStatement in extendsStatements) {
        extendsStatement.blocks.add(block);
      }

      return block;
    }

    var block = BlockStatement(name, path, body, scoped);

    addTemplateModifier((Template template) {
      template.blocks[block.name] = block;
    });

    return block;
  }

  IncludeStatement parseInlcude() {
    var oneOrList = parsePrimary();
    var ignoreMissing = false;
    if (_scanner.scan(' ignore missing')) ignoreMissing = true;
    var withContext = true;

    if (_scanner.scan(' without context')) {
      withContext = false;
    }

    _scanner.scan(' with context');
    expect(blockEndReg);

    return IncludeStatement(oneOrList, ignoreMissing: ignoreMissing, withContext: withContext);
  }

  ForStatement parseFor() {
    var elseReg = getEndRegFor('else');
    var forEndReg = getEndRegFor('endfor');
    var targets = parseAssignTarget();

    expect(spacePlusReg);
    expect('in');
    expect(spacePlusReg);

    var iterable = parseExpression(withCondition: false);
    Expression filter;

    if (_scanner.scan(ifReg)) {
      filter = parseExpression(withCondition: false);
    }

    expect(blockEndReg);

    var body = parseBody(<Pattern>[elseReg, forEndReg]);
    Node orElse;

    if (_scanner.scan(elseReg)) {
      orElse = parseBody(<Pattern>[forEndReg]);
    }

    expect(forEndReg);

    return filter != null
        ? ForStatementWithFilter(targets, iterable, body, filter, orElse: orElse)
        : ForStatement(targets, iterable, body, orElse: orElse);
  }

  IfStatement parseIf() {
    var elseReg = getEndRegFor('else');
    var ifEndReg = getEndRegFor('endif');
    var pairs = <Expression, Node>{};
    Node orElse;

    while (true) {
      if (_scanner.matches(blockEndReg)) {
        error('expect statement body');
      }

      var condition = parseExpression();

      expect(blockEndReg);

      var body = parseBody(<Pattern>['elif', elseReg, ifEndReg]);

      if (_scanner.scan('elif')) {
        _scanner.scan(spaceReg);
        pairs[condition] = body;
        continue;
      } else if (_scanner.scan(elseReg)) {
        pairs[condition] = body;
        orElse = parseBody(<Pattern>[ifEndReg]);
      } else {
        pairs[condition] = body;
      }

      break;
    }

    expect(ifEndReg);

    return IfStatement(pairs, orElse);
  }

  SetStatement parseSet() {
    var setEndReg = getEndRegFor('endset');

    expect(nameReg);

    var target = _scanner.lastMatch[1];
    String field;

    if (_scanner.scan(dotReg) && _scanner.scan(nameReg)) {
      field = _scanner.lastMatch[1];
    }

    if (_scanner.scan(assignReg)) {
      if (_scanner.matches(blockEndReg)) {
        error('expression expected');
      }

      var value = parseExpression(withCondition: false);

      expect(blockEndReg);

      return SetInlineStatement(target, value, field: field);
    }

    var filters = <Filter>[];

    while (_scanner.scan(pipeReg)) {
      var filter = parseFilter(hasLeadingPipe: false);

      if (filter == null) {
        error('filter expected but got ${filter.runtimeType}');
      }

      filters.add(filter);
    }

    expect(blockEndReg);

    var body = parseBody(<Pattern>[setEndReg]);

    expect(setEndReg);

    if (filters.isNotEmpty) {
      body = FilterBlockStatement(filters, body);
    }

    return SetBlockStatement(target, body, field: field);
  }

  RawStatement parseRaw() {
    var endRawReg = getEndRegFor('endraw', true);

    expect(getEndReg(environment.blockEnd));

    var start = _scanner.state;
    var end = start;

    while (!_scanner.isDone && !_scanner.scan(endRawReg)) {
      _scanner.readChar();
      end = _scanner.state;
    }

    var span = _scanner.spanFrom(start, end);
    return RawStatement(span.text);
  }

  FilterBlockStatement parseFilterBlock() {
    var filterEndReg = getEndRegFor('endfilter');

    if (_scanner.matches(blockEndReg)) {
      error('filter expected');
    }

    var filters = <Filter>[];

    while (_scanner.scan(pipeReg)) {
      var filter = parseFilter(hasLeadingPipe: false);

      if (filter == null) {
        error('filter expected but got ${filter.runtimeType}');
      }

      filters.add(filter);
    }

    expect(blockEndReg);

    var body = parseBody(<Pattern>[filterEndReg]);

    expect(filterEndReg);

    return FilterBlockStatement(filters, body);
  }

  List<String> parseAssignTarget({
    bool withTuple = true,
    List<Pattern> extraEndRules = const <Pattern>[],
  }) {
    CanAssign target;

    if (withTuple) {
      Object tuple = parseTuple(simplified: true, extraEndRules: extraEndRules);

      if (tuple is CanAssign) {
        target = tuple;
      } else {
        error('can\'t assign to "${target.runtimeType}"');
      }
    } else {
      expect(nameReg);

      target = Name(_scanner.lastMatch[1]);
    }

    if (target.keys.any(keywords.contains)) {
      error('expected identifer got keyword');
    }

    return target.keys;
  }

  Expression parseExpression({bool withCondition = true}) {
    if (withCondition) {
      return parseCondition();
    }

    return parseOr();
  }

  Expression parseCondition() {
    var expr = parseOr();

    while (_scanner.scan(ifReg)) {
      var testExpr = parseOr();
      Test test;
      Expression elseExpr;

      if (testExpr is Test) {
        test = testExpr;
      } else {
        test = Test('defined', expr: testExpr);
      }

      if (_scanner.scan(elseReg)) {
        elseExpr = parseCondition();
      } else {
        elseExpr = Literal<Object>(null);
      }

      expr = Condition(test, expr, elseExpr);
    }

    return expr;
  }

  Expression parseOr() {
    var left = parseAnd();

    while (_scanner.scan(orReg)) {
      left = Or(left, parseAnd());
    }

    return left;
  }

  Expression parseAnd() {
    var left = parseNot();

    while (_scanner.scan(andReg)) {
      left = And(left, parseNot());
    }

    return left;
  }

  Expression parseNot() {
    if (_scanner.scan(notReg)) {
      return Not(parseNot());
    }

    return parseCompare();
  }

  Expression parseCompare() {
    var left = parseMath1();

    while (true) {
      String op;

      if (_scanner.scan(compareReg)) {
        op = _scanner.lastMatch[1];
      } else if (_scanner.scan(inReg)) {
        op = 'in';
      } else if (_scanner.scan(notInReg)) {
        op = 'notin';
      } else {
        break;
      }

      var right = parseMath1();

      if (right == null) {
        error('Expected math expression');
      }

      switch (op) {
        case '>=':
          left = MoreEqual(left, right);
          break;
        case '>':
          left = More(left, right);
          break;
        case '<':
          left = Less(left, right);
          break;
        case '!=':
          left = Not(Equal(left, right));
          break;
        case '==':
          left = Equal(left, right);
          break;
        case 'in':
          left = Test('in', expr: left, args: <Expression>[right]);
          break;
        case 'notin':
          left = Not(Test('in', expr: left, args: <Expression>[right]));
      }
    }

    return left;
  }

  Expression parseMath1() {
    var left = parseConcat();

    while (!testAll(<Pattern>[variableEndReg, blockEndReg]) && _scanner.scan(math1Reg)) {
      var op = _scanner.lastMatch[1];
      var right = parseConcat();

      switch (op) {
        case '+':
          left = Add(left, right);
          break;
        case '-':
          left = Sub(left, right);
      }
    }

    return left;
  }

  Expression parseConcat() {
    var args = <Expression>[parseMath2()];

    while (!testAll(<Pattern>[variableEndReg, blockEndReg]) && _scanner.scan(tildaReg)) {
      args.add(parseMath2());
    }

    if (args.length == 1) {
      return args.single;
    }

    return Concat(args);
  }

  Expression parseMath2() {
    var left = parsePow();

    while (!testAll(<Pattern>[variableEndReg, blockEndReg]) && _scanner.scan(math2Reg)) {
      var op = _scanner.lastMatch[1];
      var right = parsePow();

      switch (op) {
        case '*':
          left = Mul(left, right);
          break;
        case '/':
          left = Div(left, right);
          break;
        case '//':
          left = FloorDiv(left, right);
          break;
        case '%':
          left = Mod(left, right);
      }
    }

    return left;
  }

  Expression parsePow() {
    var left = parseUnary();

    while (_scanner.scan(powReg)) {
      left = Pow(left, parseUnary());
    }

    return left;
  }

  Expression parseUnary([bool withFilter = true]) {
    Expression expr;

    if (_scanner.scan(unaryReg)) {
      switch (_scanner.lastMatch[1]) {
        case '-':
          expr = Neg(parseUnary(false));
          break;
        case '+':
          expr = parseUnary(false);
          break;
      }
    } else {
      expr = parsePrimary();
    }

    if (_scanner.isDone) {
      return expr;
    }

    expr = parsePostfix(expr);

    if (withFilter) {
      expr = parsePostfixFilter(expr);
    }

    return expr;
  }

  Expression parsePrimary() {
    Expression expr;

    if (_scanner.scan('false')) {
      expr = Literal<bool>(false);
    } else if (_scanner.scan('true')) {
      expr = Literal<bool>(true);
    } else if (_scanner.scan('none')) {
      expr = Literal<Object>(null);
    } else if (_scanner.scan(nameReg)) {
      var name = _scanner.lastMatch[1];
      var nameExpr = Name(name);
      expr = nameExpr;
      _onParseNameController.add(nameExpr);
    } else if (_scanner.scan(stringStartReg)) {
      String body;

      switch (_scanner.lastMatch[1]) {
        case '"':
          expect(stringContentDQReg, name: 'string content and double quote');
          body = _scanner.lastMatch[1];
          break;
        case "'":
          expect(stringContentSQReg, name: 'string content and single quote');
          body = _scanner.lastMatch[1];
      }

      expr = Literal<Object>(body);
    } else if (_scanner.scan(digitReg)) {
      var integer = _scanner.lastMatch[1];

      if (_scanner.scan(fractionalReg)) {
        expr = Literal<double>(double.tryParse(integer + _scanner.lastMatch[0]));
      } else {
        expr = Literal<int>(int.tryParse(integer));
      }
    } else if (_scanner.matches(lBracketReg)) {
      expr = parseList();
    } else if (_scanner.matches(lBraceReg)) {
      expr = parseMap();
    } else if (_scanner.scan(lParenReg)) {
      expr = parseTuple();
      expect(rParenReg);
    } else {
      error('primary expression expected');
    }

    return expr;
  }

  Expression parseTuple({
    bool simplified = false,
    bool withCondition = true,
    List<Pattern> extraEndRules = const <Pattern>[],
    bool explicitParentheses = false,
  }) {
    Expression Function() $parse;

    if (simplified) {
      $parse = parsePrimary;
    } else if (withCondition) {
      $parse = parseExpression;
    } else {
      $parse = () => parseExpression(withCondition: true);
    }

    var args = <Expression>[];
    var isTuple = false;

    while (!_scanner.scan(rParenReg)) {
      if (args.isNotEmpty) {
        expect(commaReg);
      }

      if (isTupleEnd(extraEndRules)) {
        break;
      }

      args.add($parse());

      if (_scanner.matches(commaReg)) {
        isTuple = true;
      } else {
        break;
      }
    }

    if (!isTuple) {
      if (args.isNotEmpty) return args.single;
      if (!explicitParentheses) error('expected an expression');
    }

    return TupleExpression(args);
  }

  bool isTupleEnd([List<Pattern> extraEndRules = const <Pattern>[]]) {
    if (testAll(<Pattern>[variableEndReg, blockEndReg, rParenReg])) return true;
    if (extraEndRules.isNotEmpty) return testAll(extraEndRules);
    return false;
  }

  Expression parseList() {
    expect(lBracketReg);

    var items = <Expression>[];

    while (!_scanner.scan(rBracketReg)) {
      if (items.isNotEmpty) expect(commaReg);
      if (_scanner.scan(rBracketReg)) break;
      items.add(parseExpression());
    }

    if (environment.optimize && items.every((Expression item) => item is Literal)) {
      return Literal<List<Object>>(
          items.map((Expression item) => (item as Literal<Object>).value).toList(growable: false));
    }

    return ListExpression(items);
  }

  Expression parseMap() {
    expect(lBraceReg);

    var items = <Expression, Expression>{};

    while (!_scanner.scan(rBraceReg)) {
      if (items.isNotEmpty) expect(commaReg);

      var key = parseExpression();

      expect(colonReg, name: 'dict entry delimeter');

      items[key] = parseExpression();
    }

    if (environment.optimize &&
        items.entries.every((MapEntry<Expression, Expression> item) => item.key is Literal && item.value is Literal)) {
      return Literal<Map<Object, Object>>(items.map((Expression key, Expression value) =>
          MapEntry<Object, Object>((key as Literal<Object>).value, (value as Literal<Object>).value)));
    }

    return MapExpression(items);
  }

  Expression parsePostfix(Expression expr) {
    while (true) {
      if (_scanner.matches(dotReg) || _scanner.matches(lBracketReg)) {
        expr = parseSubscript(expr);
      } else if (_scanner.matches(lParenReg)) {
        expr = parseCall(expr: expr);
      } else {
        break;
      }
    }

    return expr;
  }

  Expression parsePostfixFilter(Expression expr) {
    while (true) {
      if (_scanner.matches(pipeReg)) {
        expr = parseFilter(expr: expr);
      } else if (_scanner.matches(isReg)) {
        expr = parseTest(expr);
      } else if (_scanner.matches(lParenReg)) {
        expr = parseCall(expr: expr);
      } else {
        break;
      }
    }

    return expr;
  }

  Expression parseSubscript(Expression expr) {
    if (_scanner.scan(dotReg)) {
      expect(nameReg, name: 'field identifier');

      return Field(expr, _scanner.lastMatch[1]);
    }

    if (_scanner.scan(lBracketReg)) {
      var item = parseExpression();

      expect(rBracketReg);

      return Item(expr, item);
    }

    error('expected subscript expression');
  }

  Call parseCall({Expression expr}) {
    expect(lParenReg);

    var args = <Expression>[];
    var kwargs = <String, Expression>{};
    Expression argsDyn, kwargsDyn;
    var requireComma = false;

    while (!_scanner.scan(rParenReg)) {
      if (requireComma) {
        expect(commaReg);

        if (_scanner.scan(rParenReg)) break;
      }

      if (_scanner.scan('**')) {
        kwargsDyn = parseExpression();
      } else if (_scanner.scan('*')) {
        argsDyn = parseExpression();
      } else if (_scanner.scan(RegExp(nameReg.pattern + assignReg.pattern)) && argsDyn == null && kwargsDyn == null) {
        var arg = _scanner.lastMatch[1];
        var key = arg == 'default' ? '\$default' : arg;
        kwargs[key] = parseExpression();
      } else if (kwargs.isEmpty && argsDyn == null && kwargsDyn == null) {
        args.add(parseExpression());
      } else {
        error('message');
      }

      requireComma = true;
    }

    return Call(expr, args: args, kwargs: kwargs, argsDyn: argsDyn, kwargsDyn: kwargsDyn);
  }

  Filter parseFilter({Expression expr, bool hasLeadingPipe = true}) {
    if (hasLeadingPipe) expect(pipeReg);

    if (expr != null) {
      do {
        expr = _parseFilter(expr);
      } while (_scanner.scan(pipeReg));
    } else {
      expr = _parseFilter(expr);
    }

    return expr as Filter;
  }

  Expression _parseFilter(Expression expr) {
    expect(nameReg, name: 'filter name');

    var name = _scanner.lastMatch[1];

    if (_scanner.matches(lParenReg)) {
      var call = parseCall();
      expr = Filter(name, expr: expr, args: call.args, kwargs: call.kwargs);
    } else {
      expr = Filter(name, expr: expr);
    }

    return expr;
  }

  Expression parseTest(Expression expr) {
    var args = <Expression>[];
    var kwargs = <String, Expression>{};
    var negated = false;

    _scanner.scan(isReg);
    if (_scanner.scan(notReg)) negated = true;
    expect(nameReg, name: 'test name');

    var name = _scanner.lastMatch[1];

    if (_scanner.matches(lParenReg)) {
      var call = parseCall();
      args.addAll(call.args);
      kwargs.addAll(call.kwargs);
    } else if (_scanner.matches(inlineSpacePlusReg) &&
        !testAll(<Pattern>[elseReg, orReg, andReg, variableEndReg, blockEndReg])) {
      _scanner.scan(spacePlusReg);
      var arg = parsePrimary();

      if (arg is Name) {
        if (!<String>['else', 'or', 'and'].contains(arg.name)) {
          if (arg.name == 'is') {
            error('You cannot chain multiple tests with is');
          }
        }
      }

      args.add(arg);
    }

    expr = Test(name, expr: expr, args: args, kwargs: kwargs);

    if (negated) {
      expr = Not(expr);
    }

    return expr;
  }

  static final RegExp elseReg = RegExp(r'\s+else\s+');
  static final RegExp ifReg = RegExp(r'\s+if\s+');
  static final RegExp orReg = RegExp(r'\s+or\s+');
  static final RegExp andReg = RegExp(r'\s+and\s+');
  static final RegExp compareReg = RegExp(r'\s*(>=|>|<=|<|!=|==)\s*');
  static final RegExp math1Reg = RegExp(r'\s*(\+|-)\s*');
  static final RegExp tildaReg = RegExp(r'\s*~\s*');
  static final RegExp math2Reg = RegExp(r'\s*(//|/|\*|%)\s*');
  static final RegExp powReg = RegExp(r'\s*\*\*\s*');
  static final RegExp assignReg = RegExp(r'\s*=\s*');
  static final RegExp spacePlusReg = RegExp(r'\s+', multiLine: true);
  static final RegExp inlineSpacePlusReg = RegExp(r'\s+');
  static final RegExp spaceReg = RegExp(r'\s*', multiLine: true);
  static final RegExp inlineSpaceReg = RegExp(r'\s*');
  static final RegExp newLineReg = RegExp(r'(\r\n|\n)');

  static final RegExp inReg = RegExp(r'(\r\n|\n)?\s+in(\r\n|\n)?\s+');
  static final RegExp notInReg = RegExp(r'(\r\n|\n)?\s+not\s+in(\r\n|\n)?\s+');
  static final RegExp notReg = RegExp(r'not\s+');
  static final RegExp isReg = RegExp(r'(\r\n|\n)?\s+is(\r\n|\n)?\s+');
  static final RegExp pipeReg = RegExp(r'\s*\|\s*');
  static final RegExp unaryReg = RegExp(r'(-|\+)');

  static final RegExp colonReg = RegExp(r'\s*:\s*');
  static final RegExp commaReg = RegExp(r'(\r\n|\n)?\s*,(\r\n|\n)?\s*');
  static final RegExp rBraceReg = RegExp(r'\s*\}');
  static final RegExp lBraceReg = RegExp(r'\{\s*');
  static final RegExp rBracketReg = RegExp(r'\s*\]');
  static final RegExp lBracketReg = RegExp(r'\[\s*');
  static final RegExp rParenReg = RegExp(r'\s*\)');
  static final RegExp lParenReg = RegExp(r'\(\s*');
  static final RegExp dotReg = RegExp(r'\.');
  static final RegExp digitReg = RegExp(r'(\d+)');
  static final RegExp fractionalReg = RegExp(r'\.(\d+)');
  static final RegExp stringContentDQReg = RegExp('([^"]*)"');
  static final RegExp stringContentSQReg = RegExp("([^']*)'");
  static final RegExp stringStartReg = RegExp('(\\\'|\\")');
  static final RegExp nameReg = RegExp('([a-zA-Z][a-zA-Z0-9]*)');
}
