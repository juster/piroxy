#!/usr/bin/env tclsh

set sourceMap {
    {build.edn app.js {piroxy/core.cljs piroxy/blert.cljs}}
    {build-worker.edn worker.js {piroxy/worker.cljs}}
}

proc check {srcTime dest} {
    if {[catch {file stat $dest fstat}]} {
        return 1
    }
    set dstTime $fstat(mtime)
    if {$srcTime > $dstTime} {
        return 1
    }
    return 0
}

proc mtime {path} {
    file stat $path fstat
    return $fstat(mtime)
}

foreach build $sourceMap {
    lassign $build edn dest srcs
    set srcTime 0
    set dstTime 0
    foreach src $srcs {
        set t [mtime src/$src]
        if {$t > $srcTime} {
            set srcTime $t
        }
    }
    # dest may not exist
    catch {set dstTime [mtime out/$dest]}
    if {$srcTime > $dstTime} {
        puts "Building $dest..."
        exec -ignorestderr clj -M -m cljs.main -co $edn -v -c
    } else {
        puts "$dest OK"
    }
    file copy -force out/$dest ../priv/www/
    file copy -force out/$dest.map ../priv/www/
}
