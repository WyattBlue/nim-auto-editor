FFMPEG_PREFIX = $(HOME)/ffmpeg_build
FFMPEG_INCLUDE = $(FFMPEG_PREFIX)/include
FFMPEG_LIB = $(FFMPEG_PREFIX)/lib

TARGET = auto-editor
NIM_SRC = src/main.nim

all: $(TARGET)

$(TARGET): $(NIM_SRC) src/ffmpeg.nim
	nim c -d:debug --out:$(TARGET) \
		--passC:"-I$(FFMPEG_INCLUDE)" \
		--passL:"-L$(FFMPEG_LIB) -lavformat -lavcodec -lavutil -lswresample" \
		--passC:"-Wno-implicit-function-declaration" \
		$(NIM_SRC)
ifeq ($(shell uname),Darwin)
	strip -ur $(TARGET) && du --si -A $(TARGET)
else
	strip $(TARGET) && du -sh $(TARGET)
endif

clean:
	rm -f $(TARGET)

.PHONY: all clean
