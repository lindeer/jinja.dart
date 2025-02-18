import 'dart:math' as math;

import 'package:jinja/src/context.dart';
import 'package:jinja/src/runtime.dart';
import 'package:jinja/src/tests.dart';
import 'package:jinja/src/utils.dart';
import 'package:jinja/src/visitor.dart';

part 'nodes/expressions.dart';
part 'nodes/statements.dart';

typedef NodeVisitor = void Function(Node node);

abstract class Node {
  const Node();

  List<Node> get childrens {
    return const <Node>[];
  }

  R accept<C, R>(Visitor<C, R> visitor, C context);

  Iterable<T> findAll<T extends Node>() sync* {
    for (var child in childrens) {
      if (child is T) {
        yield child;
      }

      yield* child.findAll<T>();
    }
  }

  T findOne<T extends Node>() {
    var all = findAll<T>();
    return all.first;
  }

  void visitChildrens(NodeVisitor visitor) {
    childrens.forEach(visitor);
  }
}

class Data extends Node {
  Data([this.data = '']);

  String data;

  bool get isLeaf {
    return trimmed.isEmpty;
  }

  String get literal {
    return "'${data.replaceAll("'", r"\'").replaceAll('\r\n', r'\n').replaceAll('\n', r'\n')}'";
  }

  String get trimmed {
    return data.trim();
  }

  @override
  R accept<C, R>(Visitor<C, R> visitor, C context) {
    return visitor.visitData(this, context);
  }

  @override
  String toString() {
    return 'Data($literal)';
  }
}

class Output extends Node {
  Output(this.nodes);

  List<Node> nodes;

  @override
  List<Node> get childrens {
    return nodes;
  }

  @override
  R accept<C, R>(Visitor<C, R> visitor, C context) {
    return visitor.visitOutput(this, context);
  }

  @override
  String toString() {
    return 'Output(${nodes.join(', ')})';
  }

  static Node orSingle(List<Node> nodes) {
    switch (nodes.length) {
      case 0:
        return Data();
      case 1:
        return nodes[0];
      default:
        return Output(nodes);
    }
  }
}
