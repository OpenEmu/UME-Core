UME-Core
========

OpenEmu Core plugin for UME

Building
--------

You must build the `libmame_x64.a` static library before building the MAME Game core, outlined in the following steps.

**Step 1: Build mame**

The following commands will build all the MAME object files. Ignore the final link error, which is only to build the executable – we don't use the midi support.

    cd mame
    make -j 4 macosx_x64_clang SUBTARGET=arcade NOWERROR=1

**Step 2: Build libmame_x64.a**

    cd ../lib
    make SUBTARGET=arcade

