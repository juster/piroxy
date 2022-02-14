.PHONY: all erl js run clean cleanjs

all: erl js

# TODO: be less lazy if necessary
erl:
	erl -make

priv/www/main.dart.js: ui/lib/main.dart ui/lib/src/blert.dart
	cd ui; flutter build web --source-maps
	cp -r ui/build/web/* priv/www/

priv/www/blert.js: ui/js/blert.js
	cp $< $@

priv/www/worker.js: ui/js/worker.js
	cp $< $@

js: priv/www/main.dart.js priv/www/worker.js priv/www/blert.js

run: all
	sh erl.sh

clean: cleanjs
	-rm -f ebin/*.beam

cleanjs:
	-rm -rf priv/www/*
