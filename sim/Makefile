CXX      = g++
CXXFLAGS = -O2 -Wall -Wextra -std=c++14

TARGET   = ../build/jv32sim
SRC      = jv32sim.cpp riscv-dis.cpp

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p ../build
	$(CXX) $(CXXFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)
