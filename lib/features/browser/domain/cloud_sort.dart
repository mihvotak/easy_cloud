import 'cloud_node.dart';

enum CloudSortField { name, size, modifiedAt }

enum CloudSortOrder { ascending, descending }

final class CloudSort {
  const CloudSort(this.field, this.order);

  static const nameAscending = CloudSort(
    CloudSortField.name,
    CloudSortOrder.ascending,
  );

  final CloudSortField field;
  final CloudSortOrder order;

  String get apiField => switch (field) {
    CloudSortField.name => 'name',
    CloudSortField.size => 'size',
    CloudSortField.modifiedAt => 'mtime',
  };

  String get apiOrder => switch (order) {
    CloudSortOrder.ascending => 'asc',
    CloudSortOrder.descending => 'desc',
  };

  String get label => switch ((field, order)) {
    (CloudSortField.name, CloudSortOrder.ascending) => 'Имя: А–Я',
    (CloudSortField.name, CloudSortOrder.descending) => 'Имя: Я–А',
    (CloudSortField.size, CloudSortOrder.ascending) => 'Сначала маленькие',
    (CloudSortField.size, CloudSortOrder.descending) => 'Сначала большие',
    (CloudSortField.modifiedAt, CloudSortOrder.ascending) => 'Сначала старые',
    (CloudSortField.modifiedAt, CloudSortOrder.descending) => 'Сначала новые',
  };

  @override
  bool operator ==(Object other) =>
      other is CloudSort && field == other.field && order == other.order;

  @override
  int get hashCode => Object.hash(field, order);
}

const cloudSortOptions = [
  CloudSort.nameAscending,
  CloudSort(CloudSortField.name, CloudSortOrder.descending),
  CloudSort(CloudSortField.modifiedAt, CloudSortOrder.descending),
  CloudSort(CloudSortField.modifiedAt, CloudSortOrder.ascending),
  CloudSort(CloudSortField.size, CloudSortOrder.descending),
  CloudSort(CloudSortField.size, CloudSortOrder.ascending),
];

int compareCloudNodes(CloudNode left, CloudNode right, CloudSort sort) {
  final primary = switch (sort.field) {
    CloudSortField.name => _compareNames(left.name, right.name),
    CloudSortField.size => _compareNullable(
      left.size,
      right.size,
      (a, b) => a.compareTo(b),
    ),
    CloudSortField.modifiedAt => _compareNullable(
      left.modifiedAt,
      right.modifiedAt,
      (a, b) => a.compareTo(b),
    ),
  };
  if (primary != 0) {
    return sort.order == CloudSortOrder.ascending ? primary : -primary;
  }
  return left.path.compareTo(right.path);
}

int _compareNames(String left, String right) {
  final folded = left.toLowerCase().compareTo(right.toLowerCase());
  return folded == 0 ? left.compareTo(right) : folded;
}

int _compareNullable<T>(T? left, T? right, int Function(T, T) compare) {
  if (left == null) return right == null ? 0 : -1;
  if (right == null) return 1;
  return compare(left, right);
}
