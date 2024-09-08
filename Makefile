TARGET = auto-editor
ALL_SRCS = $(wildcard src/*.nim)

all: $(TARGET)

$(TARGET): $(ALL_SRCS)
	nim c -d:danger --out:$(TARGET) src/main.nim
ifeq ($(shell uname),Darwin)
	strip -ur $(TARGET) && du --si -A $(TARGET)
else
	strip $(TARGET) && du -sh $(TARGET)
endif

clean:
	rm -f $(TARGET)

.PHONY: all clean
