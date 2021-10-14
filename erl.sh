#!/bin/sh
erl -boot piroxy -config dev.mac -pz `pwd`/ebin
