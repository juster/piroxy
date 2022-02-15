import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

enum LogPlayback { live, paused }

class EventLog with ChangeNotifier {
  var _playback = LogPlayback.live;
  var log = <String>[];
  var _hidden = <String>[];

  void add(Object event){
    var str = blert.dumpJs(event);
    switch (_playback) {
      case LogPlayback.live:
        log.add(str);
        notifyListeners();
        break;
      case LogPlayback.paused:
        _hidden.add(str);
        break;
    }
  }

  void play() {
    if (_playback == LogPlayback.live) return;
    log.addAll(_hidden);
    _hidden.clear();
    _playback = LogPlayback.live;
    notifyListeners();
  }

  void pause() {
    if (_playback == LogPlayback.paused) return;
    _playback = LogPlayback.paused;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title,}) : super(key: key);

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Display events live as they occur',
            onPressed: () => context.read<EventLog>().play()
          ),
          IconButton(
            icon: const Icon(Icons.pause),
            tooltip: 'Pause the stream of events',
            onPressed: () => context.read<EventLog>().pause()
          )
        ],
      ),
      body: Consumer<EventLog>(
        builder: (context, eventlog, child) => ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: eventlog.log.length,
          itemBuilder: (BuildContext context, int i) {
            return Container(
              height: 30,
              child: Text(eventlog.log[i]),
            );
          }
        )
      )
    );
  }
}

void main() {
  var worker = BlertWorker();
  var eventlog = EventLog();
  worker.listen((data) => eventlog.add(data));
  runApp(
    ChangeNotifierProvider(
      create: (context) => eventlog,
      child: const MyApp(),
    )
  );
}
