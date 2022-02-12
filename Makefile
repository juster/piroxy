.PHONY: all erl js run

all: erl js

# TODO: be less lazy if necessary
erl:
	erl -make

ui/js/app.js: ui/lib/app.dart
	dart2js -o ui/js/app.js ui/lib/app.dart

priv/www/app.js: ui/js/app.js
	cp ui/js/app.js* priv/www/

priv/www/worker.js: ui/js/worker.js
	cp $< $@

js: priv/www/app.js priv/www/worker.js

run: all
	sh erl.sh
