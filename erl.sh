#!/bin/sh
erl -boot start_sasl -config dev.mac -pz `pwd`/ebin
