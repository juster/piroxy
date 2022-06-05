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

enum LogPlayback { record, play, pause, stop }

class EventPlayer with ChangeNotifier {
  var playback = LogPlayback.record;
  var log = <String>[];
  var _hidden = <String>[];

  void add(Object event){
    var str = blert.dumpJs(event);
    switch (playback) {
      case LogPlayback.record:
        log.add(str);
        notifyListeners();
        break;
      case LogPlayback.play:
      case LogPlayback.pause:
        _hidden.add(str);
        break;
      case LogPlayback.stop:
        break;
    }
  }

  _setPlayback(LogPlayback next) {
    if (playback == next) return;
    playback = next;
    notifyListeners();
  }

  void record() {
    if (playback == LogPlayback.record) return;
    log.addAll(_hidden);
    _hidden.clear();
    playback = LogPlayback.record;
    notifyListeners();
  }

  void stop() {
    _setPlayback(LogPlayback.stop);
  }

  void pause() {
    _setPlayback(LogPlayback.pause);
  }

  void play() {
    _setPlayback(LogPlayback.pause);
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
    return Consumer<EventPlayer>(
      builder: (context, eventlog, child) {
        var recColor = (eventlog.playback == LogPlayback.record ? Colors.red[200] : null);
        return Scaffold(
          appBar: AppBar(
            // Here we take the value from the MyHomePage object that was created by
            // the App.build method, and use it to set our appbar title.
            title: Text(widget.title),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.circle),
                color: recColor,
                tooltip: 'Record requests and responses.',
                onPressed: () => context.read<EventPlayer>().record()
              ),
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: 'Playback requests and responses.',
                onPressed: () => context.read<EventPlayer>().play()
              ),
              IconButton(
                icon: const Icon(Icons.pause),
                tooltip: 'Pause the stream but keep recording.',
                onPressed: () => context.read<EventPlayer>().pause(),
              ),
              IconButton(
                icon: const Icon(Icons.stop),
                tooltip: 'Stop recording requests and responses.',
                onPressed: () => context.read<EventPlayer>().stop(),
              ),
            ],
          ),
          body: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: eventlog.log.length,
            itemBuilder: (context, i) {
              return Container(
                height: 30,
                child: Text(eventlog.log[i]),
              );
            }
          )
        );
    });
  }
}

void main() {
  var worker = BlertWorker();
  var eventlog = EventPlayer();
  worker.listen((data) => eventlog.add(data));
  runApp(
    ChangeNotifierProvider(
      create: (context) => eventlog,
      child: const MyApp(),
    )
  );
}
