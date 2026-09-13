#import "stage-cache.hpp"

#include "key.hpp"

#if __has_feature(objc_arc)
#error "d3dmetal-pso-cache must be compiled with Objective-C automatic reference counting disabled"
#endif

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace yaagl::pso;

std::atomic<StageCompileEntry> gCompileCompute {nullptr};
std::atomic<StageCompileEntry> gCompileGraphics {nullptr};
std::atomic<StageCreateComputeKeyEntry> gCreateComputeKey {nullptr};
std::atomic<StageCreateGraphicsKeyEntry> gCreateGraphicsKey {nullptr};
std::atomic<const void*> gImageBase {nullptr};

struct Flight final {
    std::condition_variable completed;
    std::thread::id owner;
    std::size_t waiters = 0;
    bool running = true;
    bool succeeded = false;
};

struct LibraryFlight final {
    void* stageResult;
    id metalDevice;
    std::shared_ptr<Flight> state;
};

struct LibraryCallScope final {
    LibraryCallScope() noexcept { ++depth; }
    ~LibraryCallScope() { --depth; }

    static thread_local unsigned depth;
};

thread_local unsigned LibraryCallScope::depth = 0;

std::mutex gLibraryMutex;
std::vector<LibraryFlight> gLibraryFlights;

std::vector<LibraryFlight>::iterator findLibraryFlight(void* stageResult, id metalDevice) {
    for (auto entry = gLibraryFlights.begin(); entry != gLibraryFlights.end(); ++entry) {
        if (entry->stageResult == stageResult && entry->metalDevice == metalDevice) {
            return entry;
        }
    }
    return gLibraryFlights.end();
}

void eraseLibraryFlight(const std::shared_ptr<Flight>& state) {
    for (auto entry = gLibraryFlights.begin(); entry != gLibraryFlights.end(); ++entry) {
        if (entry->state == state) {
            gLibraryFlights.erase(entry);
            return;
        }
    }
}

struct OuterFlight final {
    void* cache;
    bool graphics;
    const KeyBytes* key;
    Flight* state;
};

std::mutex gOuterMutex;
std::vector<OuterFlight> gOuterFlights;

struct OuterScope final {
    OuterScope(void* cacheValue, bool graphicsValue) noexcept
        : previous(current), cache(cacheValue), graphics(graphicsValue) {
        current = this;
    }

    OuterScope(const OuterScope&) = delete;
    OuterScope& operator=(const OuterScope&) = delete;

    ~OuterScope() {
        finish(false);
        current = previous;
    }

    void finish(bool success) noexcept {
        if (finished || !owned) {
            finished = true;
            return;
        }
        finished = true;
        std::unique_lock lock(gOuterMutex);
        state.running = false;
        state.succeeded = success;
        for (auto entry = gOuterFlights.begin(); entry != gOuterFlights.end(); ++entry) {
            if (entry->state == &state) {
                gOuterFlights.erase(entry);
                break;
            }
        }
        state.completed.notify_all();
        state.completed.wait(lock, [&] { return state.waiters == 0; });
    }

    static thread_local OuterScope* current;
    OuterScope* previous;
    void* cache;
    bool graphics;
    KeyBytes key;
    Flight state;
    bool owned = false;
    bool finished = false;
};

thread_local OuterScope* OuterScope::current = nullptr;

bool sameKey(const OuterFlight& entry, void* cache, bool graphics,
             const std::uint8_t* key, std::size_t keySize) {
    return entry.cache == cache && entry.graphics == graphics
        && entry.key->size() == keySize
        && std::memcmp(entry.key->data(), key, keySize) == 0;
}

void registerOuterKey(void* nativeKey) {
    OuterScope* scope = OuterScope::current;
    if (scope == nullptr || nativeKey == nullptr || scope->owned) {
        return;
    }

    std::uint16_t keySize = 0;
    std::memcpy(&keySize, static_cast<const std::uint8_t*>(nativeKey) + 2, sizeof(keySize));
    if (keySize == 0) {
        return;
    }
    const auto* key = static_cast<const std::uint8_t*>(nativeKey);
    std::unique_lock lock(gOuterMutex);
    for (;;) {
        auto entry = gOuterFlights.begin();
        for (; entry != gOuterFlights.end(); ++entry) {
            if (sameKey(*entry, scope->cache, scope->graphics, key, keySize)) {
                break;
            }
        }
        if (entry == gOuterFlights.end()) {
            scope->key.append(key, keySize);
            scope->state.owner = std::this_thread::get_id();
            gOuterFlights.push_back(
                {scope->cache, scope->graphics, &scope->key, &scope->state});
            scope->owned = true;
            return;
        }

        Flight* state = entry->state;
        // A nested compile may hold another flight that this owner is waiting
        // for. Bypass coalescing rather than form a cross-thread wait cycle.
        if (state->running && (state->owner == std::this_thread::get_id()
                               || scope->previous != nullptr)) {
            return;
        }
        ++state->waiters;
        state->completed.wait(lock, [&] { return !state->running; });
        --state->waiters;
        if (state->waiters == 0) state->completed.notify_all();
        if (state->succeeded) {
            return;
        }
        // The failed owner removes its stack node before waking us. Looping
        // lets exactly one contender publish its own node for the retry.
    }
}

template<typename Original, typename... Args>
void* compileStages(Original original, void* cache, bool graphics, Args... args) {
    OuterScope scope(cache, graphics);
    void* result = original(cache, args...);
    scope.finish(result != nullptr);
    return result;
}

} // namespace

namespace yaagl::pso {

StageHookEntryPoints initializeStageHooks(
    const void* imageBase,
    const void* const originalTrampolines[
        static_cast<std::uint32_t>(StageOriginalSlot::Count)]) noexcept {
    if (imageBase == nullptr || originalTrampolines == nullptr) {
        return {};
    }

    const void* expected = nullptr;
    if (!gImageBase.compare_exchange_strong(
            expected, imageBase, std::memory_order_acq_rel, std::memory_order_acquire)
        && expected != imageBase) {
        return {};
    }

    const auto compute = reinterpret_cast<StageCompileEntry>(
        const_cast<void*>(originalTrampolines[static_cast<std::uint32_t>(
            StageOriginalSlot::CompileComputeStages)]));
    const auto graphics = reinterpret_cast<StageCompileEntry>(
        const_cast<void*>(originalTrampolines[static_cast<std::uint32_t>(
            StageOriginalSlot::CompileGraphicsStages)]));
    const auto computeKey = reinterpret_cast<StageCreateComputeKeyEntry>(
        const_cast<void*>(originalTrampolines[static_cast<std::uint32_t>(
            StageOriginalSlot::CreateComputeStageKey)]));
    const auto graphicsKey = reinterpret_cast<StageCreateGraphicsKeyEntry>(
        const_cast<void*>(originalTrampolines[static_cast<std::uint32_t>(
            StageOriginalSlot::CreateGraphicsStageKey)]));
    if (compute == nullptr || graphics == nullptr || computeKey == nullptr || graphicsKey == nullptr) {
        return {};
    }

    gCompileCompute.store(compute, std::memory_order_release);
    gCompileGraphics.store(graphics, std::memory_order_release);
    gCreateComputeKey.store(computeKey, std::memory_order_release);
    gCreateGraphicsKey.store(graphicsKey, std::memory_order_release);
    return {
        &yaaglPsoCompileComputeStagesHook,
        &yaaglPsoCompileGraphicsStagesHook,
        &yaaglPsoCreateComputeStageKeyHook,
        &yaaglPsoCreateGraphicsStageKeyHook,
    };
}

id getAndRetainLibrarySingleFlight(
    void* stageResult,
    id metalDevice,
    StageGetAndRetainLibraryEntry original) {
    if (stageResult == nullptr || original == nullptr) {
        return original == nullptr ? nil : original(stageResult, metalDevice);
    }

    const auto* librarySlot = reinterpret_cast<const std::uintptr_t*>(
        static_cast<std::uint8_t*>(stageResult) + 0x178);
    id completed = reinterpret_cast<id>(__atomic_load_n(librarySlot, __ATOMIC_ACQUIRE));
    if (completed != nil) {
        return original(stageResult, metalDevice);
    }

    std::shared_ptr<Flight> owned;
    {
        std::unique_lock lock(gLibraryMutex);
        for (;;) {
            auto entry = findLibraryFlight(stageResult, metalDevice);
            if (entry == gLibraryFlights.end()) {
                owned = std::make_shared<Flight>();
                owned->owner = std::this_thread::get_id();
                gLibraryFlights.push_back({stageResult, metalDevice, owned});
                break;
            }
            std::shared_ptr<Flight> state = entry->state;
            // Nested library creation can cross-call a flight whose owner is
            // waiting on this thread. Let native code resolve that rare cycle.
            if (state->running && (state->owner == std::this_thread::get_id()
                                   || LibraryCallScope::depth != 0)) {
                lock.unlock();
                return original(stageResult, metalDevice);
            }
            ++state->waiters;
            state->completed.wait(lock, [&] { return !state->running; });
            --state->waiters;
            if (state->succeeded) {
                lock.unlock();
                return original(stageResult, metalDevice);
            }
            if (!state->running) {
                state->running = true;
                state->owner = std::this_thread::get_id();
                state->succeeded = false;
                owned = std::move(state);
                break;
            }
        }
    }

    LibraryCallScope callScope;
    id result = nil;
    bool returned = false;
    try {
        @try {
            result = original(stageResult, metalDevice);
            returned = true;
        } @catch (...) {
            std::lock_guard lock(gLibraryMutex);
            owned->running = false;
            owned->succeeded = false;
            if (owned->waiters == 0) eraseLibraryFlight(owned);
            owned->completed.notify_all();
            @throw;
        }
    } catch (...) {
        if (!returned) {
            // Objective-C exceptions have already completed the flight.
            throw;
        }
        std::lock_guard lock(gLibraryMutex);
        owned->running = false;
        owned->succeeded = false;
        if (owned->waiters == 0) eraseLibraryFlight(owned);
        owned->completed.notify_all();
        throw;
    }

    {
        std::lock_guard lock(gLibraryMutex);
        owned->running = false;
        owned->succeeded = result != nil;
        if (result != nil || owned->waiters == 0) eraseLibraryFlight(owned);
        owned->completed.notify_all();
    }
    return result;
}

} // namespace yaagl::pso

extern "C" void* yaaglPsoCompileComputeStagesHook(void* cache, void* descriptor) {
    return compileStages(gCompileCompute.load(std::memory_order_acquire), cache, false, descriptor);
}

extern "C" void* yaaglPsoCompileGraphicsStagesHook(void* cache, void* descriptor) {
    return compileStages(gCompileGraphics.load(std::memory_order_acquire), cache, true, descriptor);
}

extern "C" void* yaaglPsoCreateComputeStageKeyHook(void* descriptor) {
    void* key = gCreateComputeKey.load(std::memory_order_acquire)(descriptor);
    registerOuterKey(key);
    return key;
}

extern "C" void* yaaglPsoCreateGraphicsStageKeyHook(
    void* descriptor,
    std::uintptr_t ignoredFlag,
    std::uint32_t deviceFlag) {
    void* key = gCreateGraphicsKey.load(std::memory_order_acquire)(
        descriptor, ignoredFlag, deviceFlag);
    registerOuterKey(key);
    return key;
}
