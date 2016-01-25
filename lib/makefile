# makefile to build libmame.a and copy any public header files

TARGET   := mame
MAMEPATH := ../mame
CONFIG   := Release

ifndef SUBTARGET
SUBTARGET := tiny
endif

ifndef ARCHITECTURE
ARCHITECTURE := x64
endif

OUTPUT := libmame.a

OBJDIR  := $(MAMEPATH)/build/osx_clang/obj/$(ARCHITECTURE)/$(CONFIG)
OBJECTS := \
	$(OBJDIR)/src/mame/mame.o \
	$(OBJDIR)/src/version.o \
	$(OBJDIR)/generated/$(TARGET)/$(SUBTARGET)/drivlist.o

LIBDIR := $(MAMEPATH)/build/osx_clang/bin/$(ARCHITECTURE)/$(CONFIG)
LIBS   := \
	$(LIBDIR)/lib7z.a \
	$(LIBDIR)/libbgfx.a \
	$(LIBDIR)/libexpat.a \
	$(LIBDIR)/libflac.a \
	$(LIBDIR)/libformats.a \
	$(LIBDIR)/libgtest.a \
	$(LIBDIR)/libjpeg.a \
	$(LIBDIR)/liblsqlite3.a \
	$(LIBDIR)/liblua.a \
	$(LIBDIR)/libnetlist.a \
	$(LIBDIR)/libosd_osdmini.a \
	$(LIBDIR)/libportaudio.a \
	$(LIBDIR)/libportmidi.a \
	$(LIBDIR)/libqtdbg_osdmini.a \
	$(LIBDIR)/libsoftfloat.a \
	$(LIBDIR)/libsqllite3.a \
	$(LIBDIR)/libutils.a \
	$(LIBDIR)/libzlib.a \
	$(wildcard $(LIBDIR)/$(TARGET)_$(SUBTARGET)/*.a) \

$(info Generating $(OUTPUT) $(TARGET)_$(SUBTARGET)-$(ARCHITECTURE) using $(CONFIG) build)

libmame: libmame_$(ARCHITECTURE).a

libmame_$(ARCHITECTURE).a: libmain.a libocore_osdmimi_x.a $(LIBS) 
	libtool -s -static -o libmame_$(ARCHITECTURE).a $?
	
libmain.a: $(OBJECTS)
	ar -rcs libmain.a $(OBJECTS)
	
libocore_osdmimi_x.a: $(LIBDIR)/libocore_osdmini.a
	ar -x $?
	rm minidir.o
	ar -rcs libocore_osdmimi_x.a *.o
	rm *.o "__.SYMDEF SORTED"
	