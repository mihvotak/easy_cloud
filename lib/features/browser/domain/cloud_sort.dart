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
