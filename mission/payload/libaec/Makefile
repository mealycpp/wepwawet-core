# Plain Makefile (no CMake) for the vendored libaec encoder/decoder -> libaec.a
CC ?= gcc
CFLAGS ?= -O3 -std=c99 -Wall
OBJ = src/encode.o src/encode_accessors.o src/decode.o src/vector.o
libaec.a: $(OBJ)
	$(AR) rcs $@ $(OBJ)
src/%.o: src/%.c
	$(CC) $(CFLAGS) -Iinclude -Isrc -c $< -o $@
clean:
	rm -f $(OBJ) libaec.a
