# Copyright 2021 Google LLC
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.

# This Makefile depends on the Google grpc library.

# Directory where Google's gRPC library is installed. This should be
# the same directory you gave as the --prefix option to ./configure
# when installing it.
GRPC_ROOT ?= /usr/local
CXXFLAGS = -std=c++17 $(shell pkg-config grpc --cflags) -I$(GRPC_ROOT)/include -fPIC
LDFLAGS = $(shell pkg-config grpc --libs) -lgpr
OFILES = client.o client_auth.o server.o

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LIB = grpc.dylib
  # Bundle copies libgrpc*.dylib next to grpc.dylib; @loader_path finds them.
  SOFLAGS = -dynamiclib -Wl,-rpath,@loader_path
else
  LIB = grpc.so
  # Bundle copies libgrpc*.so next to grpc.so; $ORIGIN finds them at dlopen time.
  SOFLAGS = -shared -Wl,--no-undefined -Wl,-rpath,\$$ORIGIN
endif

# Default target if make is run with no arguments.
default_target: $(LIB)

.PHONY : default_target clean

$(LIB): $(OFILES)
	$(CXX) -pthread $(SOFLAGS) $(OFILES) -o $@ $(LDFLAGS)

clean:
	$(RM) $(OFILES) grpc.so grpc.dylib

client.o: client.cc
client_auth.o: client_auth.cc
server.o: server.cc
