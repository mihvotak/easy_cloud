import 'dart:convert';

final class CloudResponse {
  const CloudResponse({required this.statusCode, required this.bytes});

  final int statusCode;
  final List<int> bytes;

  Object? get json => jsonDecode(utf8.decode(bytes));
}

abstract interface class CloudTransport {
  Future<CloudResponse> get(
    String endpoint, {
    Map<String, String> query = const {},
    bool includeCsrfQuery = false,
  });

  void close();
}
