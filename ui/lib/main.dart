import 'package:flutter/material.dart';
import 'dart:html';
import 'dart:async';
import 'src/blert.dart' as blert;

class BlertWorker {
  final incoming = StreamController<Object>();
  Timer? timer = null;
  List<Object> queue = [];

  BlertWorker() {
    var worker = new Worker('https://piroxy/worker.js');
    var timer = Timer.periodic(Duration(seconds: 5), (_) {
        var tuple = blert.fromDart(
          {"tuple": [{"atom":"echo"}, {"tuple": [{"atom":"hello"}, {"atom":"world"}]}]}
        );
        worker.postMessage(tuple);
    });
    worker.onMessage.listen((e) => incoming.add(e.data));
    worker.onError.listen((e) {
        incoming.addError(e);
        timer.cancel();
    });
  }

  void listen(fun) {
    incoming.stream.listen(fun);
  }
}

class MyApp extends StatelessWidget {
  final BlertWorker transport;

  const MyApp(this.transport, {Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(
        title: 'Flutter Demo Home Page',
        transport: transport,
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({
      Key? key,
      required this.title,
      required this.transport
  }) : super(key: key);

  final String title;
  final BlertWorker transport;

  @override
  State<MyHomePage> createState() => _MyHomePageState(transport);
}

enum LogPlayback { live, paused }

class _MyHomePageState extends State<MyHomePage> {
  var _playback = LogPlayback.live;
  List<String> messages = [];
  List<String> queued = [];

  _MyHomePageState(BlertWorker transport) {
    transport.listen(_receiveMessage);
  }

  void _receiveMessage(Object msg) {
    switch (_playback) {
      case LogPlayback.live:
        setState(() {
            var str = blert.dumpJs(msg);
            messages.add(str);
        });
        break;
      case LogPlayback.paused:
        queued.add(blert.dumpJs(msg));
        break;
    }
  }

  void pause() {
    if (_playback == LogPlayback.paused) return;
    setState() {
      _playback = LogPlayback.paused;
    }
  }

  void resume() {
    if (_playback == LogPlayback.live) return;
    setState() {
      messages.addAll(queued);
      queued.clear();
      _playback = LogPlayback.live;
    }
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Display events live as they occur',
            onPressed: resume,
          ),
          IconButton(
            icon: const Icon(Icons.pause),
            tooltip: 'Pause the stream of events',
            onPressed: pause,
          )
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: messages.length,
        itemBuilder: (BuildContext context, int i) {
          return Container(
            height: 30,
            child: Text(messages[i]),
          );
        }
      )
    );
  }
}

void main() {
  var worker = BlertWorker();
  runApp(MyApp(worker));
}
