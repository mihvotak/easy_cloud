import 'package:easy_cloud/features/browser/domain/cloud_node.dart';
import 'package:easy_cloud/features/browser/domain/cloud_sort.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('name sorting interleaves letter case', () {
    final nodes = ['b', 'A', 'a', 'B', 'c']
        .map(
          (name) =>
              CloudNode(path: '/$name', name: name, type: CloudNodeType.file),
        )
        .toList();

    nodes.sort(
      (left, right) => compareCloudNodes(left, right, CloudSort.nameAscending),
    );

    expect(nodes.map((node) => node.name), ['A', 'a', 'B', 'b', 'c']);
  });
}
