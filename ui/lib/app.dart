import 'dart:html';
import 'dart:async';
import 'blert.dart' as blert;

main() {
  var worker = new Worker('https://piroxy/worker.js');
  var timer = Timer.periodic(Duration(seconds: 5), (_) {
      var tuple = blert.tuple([blert.atom("echo"), blert.atom("hello")]);
      worker.postMessage(tuple);
  });
  worker.onMessage.listen((e) {
      print("*DBG* received: ${e.data}");
  });
  worker.onError.listen((e) {
      print("*DBG* worker error: $e");
      timer.cancel();
  });
}
