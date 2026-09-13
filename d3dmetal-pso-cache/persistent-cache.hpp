#pragma once

#include <cstddef>
#include <cstdint>

namespace yaagl::pso {

struct PersistentCacheWarmupResult final {
    std::size_t directoriesVisited = 0;
    std::size_t filesAdvised = 0;
    std::uint64_t bytesAdvised = 0;
};

// Advises the kernel to read ahead a bounded prefix of D3DMetal's existing
// persistent cache files. All errors are deliberately reported only through
// the counters: startup and native cache loading must remain authoritative.
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
PersistentCacheWarmupResult warmPersistentCachesAt(
    const char* cacheRoot, const char* executableName) noexcept;
#endif

// Runs only when YAAGL_D3DMETAL_CACHE_WARMUP is exactly "1". Production uses
// _CS_DARWIN_USER_CACHE_DIR and getprogname; isolated test builds may enable
// compile-time-only root and executable controls.
PersistentCacheWarmupResult warmPersistentCachesFromEnvironment() noexcept;

#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
void setFdopendirFailureForTest(bool fail) noexcept;
int lastFdopendirFdForTest() noexcept;
#endif

} // namespace yaagl::pso
