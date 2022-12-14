UME-Core
========

OpenEmu Core plugin for UME

Building
--------

You must build the `mamearcade_headless.dylib` dynamic library before building the MAME Game core:

```sh
$ cd deps/mame
$ make macosx_x64_clang OSD="headless" verbose=1 TARGETOS="macosx" CONFIG="release" TARGET=mame SUBTARGET=arcade MACOSX_DEPLOYMENT_TARGET=12.4 -j8
$ install_name_tool -id mamearcade_headless.dylib mamearcade_headless.dylib     
```

Depending on your hardware, this could take a _long_ time, but if successful, you will have a file named `mamearcade_headless.dylib` in the current directory.

Build the UME project, which will link and embed this binary and update the loader path automatically.

