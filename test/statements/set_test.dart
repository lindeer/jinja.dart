import 'package:jinja/jinja.dart';
import 'package:test/test.dart';

void main() {
  final env = Environment();

  test('simple', () {
    // TODO: trim_blocks env
    final template = env.fromSource('{% set foo = 1 %}{{ foo }}');
    expect(template.testRender(), equals('1'));
    // TODO: test module foo == 1
  });

  test('block', () {
    // TODO: trim_blocks env
    final template = env.fromSource('{% set foo %}42{% endset %}{{ foo }}');
    expect(template.testRender(), equals('42'));
    // TODO: test module foo == '42'
  });
}
