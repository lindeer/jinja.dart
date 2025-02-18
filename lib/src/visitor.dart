import 'package:jinja/src/environment.dart';
import 'package:jinja/src/nodes.dart';

typedef ExpressionUpdater = Expression Function(Expression expression);

abstract class Visitor<C, R> {
  const Visitor();

  void visitAll(List<Node> nodes, C context) {
    for (var node in nodes) {
      node.accept(this, context);
    }
  }

  R visitAssign(Assign node, C context);

  R visitAssignBlock(AssignBlock node, C context);

  R visitAutoEscape(AutoEscape node, C context);

  R visitBlock(Block node, C context);

  R visitData(Data node, C context);

  R visitDo(Do node, C context);

  R visitExpression(Expression node, C context);

  R visitExtends(Extends node, C context);

  R visitFilterBlock(FilterBlock node, C context);

  R visitFor(For node, C context);

  R visitIf(If node, C context);

  R visitInclude(Include node, C context);

  R visitOutput(Output node, C context);

  R visitTemplate(Template node, C context);

  R visitWith(With node, C context);
}

abstract class ThrowingVisitor<C, R> implements Visitor<C, R> {
  const ThrowingVisitor();

  Never fail(Node node, C context) {
    throw UnimplementedError(node.runtimeType.toString());
  }

  @override
  void visitAll(List<Node> nodes, C context) {
    for (var node in nodes) {
      node.accept(this, context);
    }
  }

  @override
  R visitAssign(Assign node, C context) {
    fail(node, context);
  }

  @override
  R visitAssignBlock(AssignBlock node, C context) {
    fail(node, context);
  }

  @override
  R visitBlock(Block node, C context) {
    fail(node, context);
  }

  @override
  R visitData(Data node, C context) {
    fail(node, context);
  }

  @override
  R visitDo(Do node, C context) {
    fail(node, context);
  }

  @override
  R visitExpression(Expression node, C context) {
    fail(node, context);
  }

  @override
  R visitExtends(Extends node, C context) {
    fail(node, context);
  }

  @override
  R visitFilterBlock(FilterBlock node, C context) {
    fail(node, context);
  }

  @override
  R visitFor(For node, C context) {
    fail(node, context);
  }

  @override
  R visitIf(If node, C context) {
    fail(node, context);
  }

  @override
  R visitInclude(Include node, C context) {
    fail(node, context);
  }

  @override
  R visitOutput(Output node, C context) {
    fail(node, context);
  }

  @override
  R visitTemplate(Template node, C context) {
    fail(node, context);
  }

  @override
  R visitWith(With node, C context) {
    fail(node, context);
  }
}

class ExpressionMapper extends Visitor<ExpressionUpdater, void> {
  const ExpressionMapper();

  @override
  void visitAll(List<Node> nodes, ExpressionUpdater context) {
    for (var i = 0; i < nodes.length; i += 1) {
      var node = nodes[i];

      if (node is Expression) {
        nodes[i] = visitExpression(node, context);
      } else {
        node.accept(this, context);
      }
    }
  }

  @override
  void visitAssign(Assign node, ExpressionUpdater context) {
    node.target = visitExpression(node.target, context);
    node.value = visitExpression(node.value, context);
  }

  @override
  void visitAssignBlock(AssignBlock node, ExpressionUpdater context) {
    node.target = visitExpression(node.target, context);

    var body = node.body;

    if (body is Expression) {
      node.body = visitExpression(body, context);
    }

    var filters = node.filters;

    if (filters != null) {
      visitAll(filters, context);
    }
  }

  @override
  void visitAutoEscape(AutoEscape node, ExpressionUpdater context) {
    node.value = visitExpression(node.value, context);
  }

  @override
  void visitBlock(Block node, ExpressionUpdater context) {
    var body = node.body;

    if (body is Expression) {
      node.body = visitExpression(body, context);
    } else {
      body.accept(this, context);
    }
  }

  @override
  void visitData(Data node, ExpressionUpdater context) {}

  @override
  void visitDo(Do node, ExpressionUpdater context) {
    node.expression = visitExpression(node.expression, context);
  }

  @override
  Expression visitExpression(Expression node, ExpressionUpdater context) {
    node.update(context);
    return context(node);
  }

  @override
  void visitExtends(Extends node, ExpressionUpdater context) {}

  @override
  void visitFilterBlock(FilterBlock node, ExpressionUpdater context) {
    visitAll(node.filters, context);

    var body = node.body;

    if (body is Expression) {
      node.body = visitExpression(body, context);
    } else {
      body.accept(this, context);
    }
  }

  @override
  void visitFor(For node, ExpressionUpdater context) {
    node.target = visitExpression(node.target, context);
    node.iterable = visitExpression(node.iterable, context);

    var test = node.test;

    if (test != null) {
      node.test = visitExpression(test, context);
    }

    var body = node.body;

    if (body is Expression) {
      node.body = visitExpression(body, context);
    } else {
      body.accept(this, context);
    }

    var orElse = node.orElse;

    if (orElse is Expression) {
      node.orElse = visitExpression(orElse, context);
    } else if (orElse != null) {
      orElse.accept(this, context);
    }
  }

  @override
  void visitIf(If node, ExpressionUpdater context) {
    node.test = visitExpression(node.test, context);

    var body = node.body;

    if (body is Expression) {
      node.body = visitExpression(body, context);
    } else {
      body.accept(this, context);
    }

    var orElse = node.orElse;

    if (orElse is Expression) {
      node.orElse = visitExpression(orElse, context);
    } else if (orElse != null) {
      orElse.accept(this, context);
    }
  }

  @override
  void visitInclude(Include node, ExpressionUpdater context) {}

  @override
  void visitOutput(Output node, ExpressionUpdater context) {
    visitAll(node.nodes, context);
  }

  @override
  void visitTemplate(Template node, ExpressionUpdater context) {
    node.body.accept(this, context);
    visitAll(node.blocks, context);
  }

  @override
  void visitWith(With node, ExpressionUpdater context) {
    visitAll(node.targets, context);
    visitAll(node.values, context);

    var body = node.body;

    if (body is Expression) {
      node.body = visitExpression(body, context);
    } else {
      body.accept(this, context);
    }
  }
}
