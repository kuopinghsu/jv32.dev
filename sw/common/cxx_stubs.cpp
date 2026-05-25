// ============================================================================
// File   : sw/common/cxx_stubs.cpp
// Project: JV32 RISC-V SoC
// Brief  : C++ runtime stubs for freestanding / no-libstdc++ mode.
//
// When linking with -nostdlib++ (required because the riscv64-unknown-elf
// toolchain only ships 64-bit libstdc++/libsupc++ which cannot be linked
// into a 32-bit ELF), g++ no longer provides operator new/delete.
// This file supplies minimal implementations backed by newlib malloc/free.
//
// GCC 15+ libstdc++ requires exception support functions to be defined
// even when -fno-exceptions is used. This file provides minimal stubs
// that call std::terminate() (which defaults to abort()).
//
// These definitions are placed in the std namespace with external linkage
// so the linker can resolve them during library instantiation.
// ============================================================================

#include <cstddef>
#include <cstdlib>

// ---------------------------------------------------------------------------
// std::terminate  (called on unrecoverable C++ errors; not in libstdc++ when
// linking with -nostdlib++, so provide a minimal implementation here)
// ---------------------------------------------------------------------------
namespace std {
    [[noreturn]] void terminate() noexcept { std::abort(); }
}  // namespace std

// ---------------------------------------------------------------------------
// operator new / delete  (backed by newlib malloc/free)
// With -fno-exceptions, allocation failure calls std::terminate() rather
// than throwing std::bad_alloc; this is the standard embedded C++ mode.
// ---------------------------------------------------------------------------
void *operator new(std::size_t sz)
{
    void *p = std::malloc(sz ? sz : 1);
    if (!p) std::terminate();
    return p;
}

void *operator new[](std::size_t sz)
{
    void *p = std::malloc(sz ? sz : 1);
    if (!p) std::terminate();
    return p;
}

void operator delete(void *p) noexcept
{
    std::free(p);
}

void operator delete[](void *p) noexcept
{
    std::free(p);
}

// C++14 sized deallocation (called by GCC 15+ delete expressions)
void operator delete(void *p, std::size_t) noexcept
{
    std::free(p);
}

void operator delete[](void *p, std::size_t) noexcept
{
    std::free(p);
}

// ---------------------------------------------------------------------------
// Exception support stubs
// ---------------------------------------------------------------------------
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
