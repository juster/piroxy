library blert;

import 'dart:js_util';
import 'package:js/js.dart';

@JS()
@anonymous
class Blert {
}

@JS()
@anonymous
class BlertAtom extends Blert {
  external String get atom;
  external factory BlertAtom({String atom});
}

@JS()
@anonymous
class BlertTuple extends Blert {
  external String get tuple;
  external factory BlertTuple({List<Blert> tuple});
}

BlertTuple tuple(Iterable<Blert> tuple){
  return BlertTuple(tuple: List<Blert>.from(tuple));
}

BlertAtom atom(String atom){
  return BlertAtom(atom: atom);
}
