library blert;

import 'dart:js_util' as js;
import 'package:js/js.dart';

@JS()
@anonymous
class BlertJs {
  String toString();
}

@JS()
@anonymous
class BlertAtom extends BlertJs {
  external String get atom;
  external factory BlertAtom({String atom});
}

@JS()
@anonymous
class BlertTuple extends BlertJs {
  external List<BlertJs> get tuple;
  external factory BlertTuple({List<BlertJs> tuple});
}

BlertJs fromDart(Object? obj) {
  if(obj == null){
    return BlertAtom(atom: "null");
  }else if (obj is Symbol){
    return BlertAtom(atom: obj.toString());
  }else if(obj is Map<String,Object?>){
    var m = obj as Map<String,Object?>;
    if(m["tuple"] != null){
      var lst = m["tuple"] as List<Object>;
      return BlertTuple(tuple: lst.map(fromDart).toList());
    }else if (m["atom"] != null){
      return BlertAtom(atom: m["atom"] as String);
    }else{
      throw "bad blert";
    }
  }else{
    throw "bad blert";
  }
}

String dumpJs(Object obj){
  if(obj == null){
    return "null";
  }else if(obj is num) {
    return "$obj";
  }else if(obj is String) {
    return '"' + obj.replaceAll(RegExp(r'"'), '\\"') + '"';
  }else if(obj is Map<dynamic,dynamic>){
    if(obj.containsKey("atom")){
      return "'${obj['atom']}'";
    }else if (obj.containsKey("tuple")){
      var lst = obj["tuple"] as List<Object>;
      return '[' + obj["tuple"].map((x) => dumpJs(x)).join(",") + ']';
    }else if (obj.containsKey("list")){
      var lst = obj["list"] as List<Object>;
      return '{' + obj["list"].map((x) => dumpJs(x)).join(",") + '}';
    }else{
      throw "bad blert";
    }
  }else {
    throw "bad blert";
  }
}
