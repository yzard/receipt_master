import 'dart:async';

class RequestTimeout extends TimeoutException {
  RequestTimeout() : super('Timeout');
  @override
  String toString() => 'Timeout';
}
