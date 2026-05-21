CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -pthread
TARGET := main
SRC := main.c api.c config.c gpio.c log.c serial.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC)


clean:
	rm -f $(TARGET)