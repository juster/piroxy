library blert;

import 'dart:js';
import 'dart:js_util';
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
  external List<dynamic> get tuple;
  external factory BlertTuple({List<dynamic> tuple});
}

/*
@JS('Array')
class JsArray {
  external num get length;
  external JsArray();
  external static bool isArray(Object? obj);
  external void push(Object? obj);
}
*/

BlertJs fromDart(Object? obj) {
  if(obj == null){
    return BlertAtom(atom: "null");
  }else if (obj is Symbol){
    return BlertAtom(atom: obj.toString());
  }else if(obj is Map<String,Object?>){
    var m = obj as Map<String,Object?>;
    if(m["tuple"] != null){
      var lst = m["tuple"] as List<Object?>;
      return BlertTuple(tuple: List<dynamic>.from(lst.map(fromDart)));
    }else if (m["atom"] != null){
      return BlertAtom(atom: m["atom"] as String);
    }else{
      throw "bad blert";
    }
  }else{
    throw "bad blert";
  }
}

String dumpJs(dynamic? obj){
  if(obj == null){
    return "null";
  }else if(obj is num) {
    return "$obj";
  }else if(obj is String) {
    return '"' + obj.replaceAll(RegExp(r'"'), '\\"') + '"';
  }else if(obj is Map<dynamic,dynamic?>) {
    if(obj["atom"] != null){
      return "'${obj['atom']}'";
    }else if(obj["tuple"] != null){
      return '{' + obj["tuple"].map(dumpJs).join(",") + '}';
    }else{
      throw "bad blert: $obj";
    }
  }else{
    throw "bad blert: $obj";
  }
}
