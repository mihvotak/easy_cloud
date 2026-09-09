enum CloudNodeType { file, folder, unknown }

final class CloudNode {
  const CloudNode({
    required this.path,
    required this.name,
    required this.type,
    this.kind,
    this.size,
    this.modifiedAt,
    this.hash,
    this.revision,
    this.globalRevision,
    this.tree,
    this.webLink,
    this.virusScan,
    this.fileCount,
    this.folderCount,
  });

  final String path;
  final String name;
  final CloudNodeType type;
  final String? kind;
  final int? size;
  final DateTime? modifiedAt;
  final String? hash;
  final String? revision;
  final String? globalRevision;
  final String? tree;
  final String? webLink;
  final String? virusScan;
  final int? fileCount;
  final int? folderCount;

  bool get isFolder => type == CloudNodeType.folder;
}
