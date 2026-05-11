// ============================================================================
// File   : sw/common/cxx_stubs.cpp
// Project: JV32 RISC-V SoC
// Brief  : C++ exception function stubs for freestanding mode.
//
// GCC 15+ libstdc++ requires exception support functions to be defined
// even when -fno-exceptions is used. This file provides minimal stubs
// that call std::terminate() (which defaults to abort()).
//
// These definitions are placed in the std namespace with external linkage
// so the linker can resolve them during library instantiation.
// ============================================================================

#include <cstdlib>
#include <exception>

namespace std {

// Called by new[] operator when allocation fails
[[gnu::weak]]
void __throw_bad_alloc() {
    std::terminate();
}

// Called by std::vector and other containers for bad array sizes
[[gnu::weak]]
void __throw_bad_array_new_length() {
    std::terminate();
}

// Called by std::vector and other containers when length exceeds max_size()
[[gnu::weak]]
void __throw_length_error(const char *) {
    std::terminate();
}

}  // namespace std

// Also define in global namespace for any code that might use unqualified names
using std::__throw_bad_alloc;
using std::__throw_bad_array_new_length;
using std::__throw_length_error;
