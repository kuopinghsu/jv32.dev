// ============================================================================
// File   : sw/cpp/cpp_test.cpp
// Project: JV32 RISC-V SoC
// Brief  : C++ / newlib integration test.
//
// Verified features:
//   1.  Global constructors        – sequenced before main() via .init_array
//   2.  std::vector<int>           – heap alloc via _sbrk → malloc/new
//   3.  std::array<int,N>          – stack-allocated fixed-size container
//   4.  std::sort / is_sorted      – introsort on dynamic and static ranges
//   5.  std::find / find_if        – linear search with lambda predicate
//   6.  std::fill / iota           – range mutation
//   7.  std::accumulate            – fold / reduce
//   8.  std::min_element / max     – range extrema
//   9.  std::transform             – element-wise lambda
//  10.  operator new / delete      – linked-list heap allocation
//  11.  Placement new              – in-place construction into char buffer
//  12.  Move semantics             – std::move, move constructor, vector<T&&>
//
// Compile flags: -fno-exceptions -fno-rtti
//   Full exception unwinding requires keeping .eh_frame in link.ld plus a
//   larger IRAM (the full libstdc++ unwind runtime exceeds 128 KB).
//   With -fno-exceptions, allocation failures call std::terminate() rather
//   than throwing std::bad_alloc; this is the standard embedded C++ mode.
// ============================================================================

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <new>
#include <numeric>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------
// Minimal test framework
// ---------------------------------------------------------------------------
static int s_pass, s_fail;

static void check(const char *name, bool ok)
{
    if (ok) { printf("  PASS  %s\n", name); s_pass++; }
    else     { printf("  FAIL  %s\n", name); s_fail++; }
}

// ---------------------------------------------------------------------------
// 1. Global constructors – record order of construction before main()
// ---------------------------------------------------------------------------
static int g_ctor_order[4];
static int g_ctor_next;

struct OrderTracker {
    int index;
    explicit OrderTracker(int i) : index(i) {
        if (g_ctor_next < 4) g_ctor_order[g_ctor_next++] = index;
    }
};

static OrderTracker g_a(1);
static OrderTracker g_b(2);
static OrderTracker g_c(3);

// ---------------------------------------------------------------------------
// 10. operator new / delete – singly-linked list on heap
// ---------------------------------------------------------------------------
struct HeapNode {
    int       val;
    HeapNode *next;
    explicit HeapNode(int v, HeapNode *n = nullptr) : val(v), next(n) {}
};

// ---------------------------------------------------------------------------
// 12. Move semantics – non-copyable resource wrapper
// ---------------------------------------------------------------------------
struct MoveOnly {
    int *data;
    int  size;

    explicit MoveOnly(int n) : data(new int[n]), size(n) {
        for (int i = 0; i < n; i++) data[i] = i * i;
    }
    MoveOnly(MoveOnly &&o) noexcept : data(o.data), size(o.size) {
        o.data = nullptr;
        o.size = 0;
    }
    MoveOnly(const MoveOnly &) = delete;
    MoveOnly &operator=(const MoveOnly &) = delete;
    ~MoveOnly() { delete[] data; }
};

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main()
{
    printf("=== C++ / newlib integration test ===\n\n");
    s_pass = s_fail = 0;

    // 1. Global constructors -------------------------------------------------
    printf("-- 1. Global constructors --\n");
    check("ctor_order[0]==1", g_ctor_order[0] == 1);
    check("ctor_order[1]==2", g_ctor_order[1] == 2);
    check("ctor_order[2]==3", g_ctor_order[2] == 3);
    check("g_ctor_next==3",   g_ctor_next == 3);

    // 2. std::vector<int> ----------------------------------------------------
    printf("-- 2. std::vector<int> --\n");
    std::vector<int> v;
    for (int i = 0; i < 8; i++) v.push_back(i * 3);
    check("size==8",             v.size() == 8);
    check("[0]==0",              v[0] == 0);
    check("[7]==21",             v[7] == 21);
    v.erase(v.begin() + 3);
    check("after erase: size==7",v.size() == 7);
    v.insert(v.begin(), 99);
    check("after insert: [0]==99",v[0] == 99);

    // 3. std::array<int,8> ---------------------------------------------------
    printf("-- 3. std::array<int,8> --\n");
    std::array<int, 8> arr;
    arr.fill(7);
    check("fill: [0]==7",     arr[0] == 7);
    check("fill: [7]==7",     arr[7] == 7);
    check("size==8",          arr.size() == 8);
    bool all7 = true;
    for (auto x : arr) if (x != 7) all7 = false;
    check("range-for all 7",  all7);

    // 4. std::sort / is_sorted -----------------------------------------------
    printf("-- 4. std::sort / is_sorted --\n");
    std::vector<int> sv = {5, 2, 8, 1, 9, 3, 7, 4, 6, 0};
    check("pre-sort: !is_sorted", !std::is_sorted(sv.begin(), sv.end()));
    std::sort(sv.begin(), sv.end());
    check("post-sort: is_sorted", std::is_sorted(sv.begin(), sv.end()));
    check("[0]==0",               sv[0] == 0);
    check("[9]==9",               sv[9] == 9);
    std::sort(sv.begin(), sv.end(), std::greater<int>());
    check("reverse: [0]==9",      sv[0] == 9);

    // 5. std::find / find_if -------------------------------------------------
    printf("-- 5. std::find / find_if --\n");
    auto it = std::find(sv.begin(), sv.end(), 5);
    check("find 5: found",        it != sv.end() && *it == 5);
    it = std::find(sv.begin(), sv.end(), 42);
    check("find 42: not found",   it == sv.end());
    auto it2 = std::find_if(sv.begin(), sv.end(), [](int x){ return x < 3; });
    check("find_if x<3: found",   it2 != sv.end() && *it2 < 3);

    // 6. std::fill / iota ----------------------------------------------------
    printf("-- 6. std::fill / iota --\n");
    std::vector<int> fv(6);
    std::fill(fv.begin(), fv.end(), 42);
    check("fill: [0]==42",        fv[0] == 42);
    check("fill: [5]==42",        fv[5] == 42);
    std::iota(fv.begin(), fv.end(), 10);
    check("iota: [0]==10",        fv[0] == 10);
    check("iota: [5]==15",        fv[5] == 15);

    // 7. std::accumulate -----------------------------------------------------
    printf("-- 7. std::accumulate --\n");
    int sum = std::accumulate(fv.begin(), fv.end(), 0);
    check("sum==75",              sum == (10+11+12+13+14+15));
    int prod = std::accumulate(fv.begin(), fv.begin() + 3, 1,
                               [](int a, int b){ return a * b; });
    check("product 10*11*12==1320", prod == 1320);

    // 8. std::min_element / max_element --------------------------------------
    printf("-- 8. min_element / max_element --\n");
    auto mn = std::min_element(sv.begin(), sv.end());
    auto mx = std::max_element(sv.begin(), sv.end());
    check("min==0",               *mn == 0);
    check("max==9",               *mx == 9);

    // 9. std::transform -------------------------------------------------------
    printf("-- 9. std::transform --\n");
    std::vector<int> src = {1, 2, 3, 4, 5};
    std::vector<int> dst(5);
    std::transform(src.begin(), src.end(), dst.begin(),
                   [](int x){ return x * x; });
    check("[0]==1",               dst[0] == 1);
    check("[4]==25",              dst[4] == 25);

    // 10. operator new / delete -----------------------------------------------
    printf("-- 10. operator new/delete --\n");
    HeapNode *list = new HeapNode(3, new HeapNode(2, new HeapNode(1)));
    check("list[0]==3",           list->val == 3);
    check("list[2]==1",           list->next->next->val == 1);
    for (HeapNode *cur = list, *nx; cur; cur = nx) {
        nx = cur->next;
        delete cur;
    }
    int *arr2 = new int[32];
    for (int i = 0; i < 32; i++) arr2[i] = i;
    check("new int[32][0]==0",    arr2[0] == 0);
    check("new int[32][31]==31",  arr2[31] == 31);
    delete[] arr2;

    // 11. Placement new -------------------------------------------------------
    printf("-- 11. Placement new --\n");
    alignas(HeapNode) char buf[sizeof(HeapNode)];
    HeapNode *pn = new (buf) HeapNode(77);
    check("val==77",              pn->val == 77);
    check("addr == buf",          static_cast<void *>(pn) == static_cast<void *>(buf));
    pn->~HeapNode();

    // 12. Move semantics ------------------------------------------------------
    printf("-- 12. Move semantics --\n");
    MoveOnly mo(4);
    check("before move: [3]==9",  mo.data[3] == 9);
    MoveOnly mo2(std::move(mo));
    check("after move: src null", mo.data == nullptr);
    check("after move: [3]==9",   mo2.data[3] == 9);
    std::vector<MoveOnly> mv;
    mv.push_back(MoveOnly(3));
    check("vector<MoveOnly>: size==1",    mv.size() == 1);
    check("vector<MoveOnly>: [0][2]==4",  mv[0].data[2] == 4);

    // Summary -----------------------------------------------------------------
    printf("\n=== SUMMARY: %d PASS, %d FAIL ===\n", s_pass, s_fail);
    return s_fail == 0 ? 0 : 1;
}
