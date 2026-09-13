#import "stage-cache.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

#define CHECK(condition) do { \
    if (!(condition)) { \
        std::cerr << __FILE__ << ':' << __LINE__ << ": check failed: " #condition << '\n'; \
        std::abort(); \
    } \
} while (false)

std::atomic<int> gLibraryDeallocations {0};

@interface CountedLibrary : NSObject
@end
@implementation CountedLibrary
- (void)dealloc {
    ++gLibraryDeallocations;
    [super dealloc];
}
@end

namespace {

class Latch final {
public:
    explicit Latch(int target) : target_(target) {}

    void arriveAndWait() {
        std::unique_lock lock(mutex_);
        ++arrived_;
        condition_.notify_all();
        condition_.wait(lock, [&] { return open_; });
    }

    void waitForArrivals() {
        std::unique_lock lock(mutex_);
        condition_.wait(lock, [&] { return arrived_ >= target_; });
    }

    void open() {
        std::lock_guard lock(mutex_);
        open_ = true;
        condition_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    int target_;
    int arrived_ = 0;
    bool open_ = false;
};

struct StageStorage final {
    alignas(void*) std::uint8_t bytes[0x180] {};
};

std::atomic<int> libraryCreates {0};
std::atomic<int> libraryFailures {0};
std::atomic<int> libraryCppThrows {0};
std::atomic<int> libraryObjcThrows {0};
std::atomic<bool> recurseLibrary {false};
std::atomic<unsigned> libraryCycleEntered {0};
void* libraryCycleStages[2] {};
Latch* libraryCycleLatch = nullptr;
struct LibraryException final {};
Latch* libraryCreatorLatch = nullptr;

id fakeGetAndRetainLibrary(void* stageResult, id device) {
    auto* slot = reinterpret_cast<std::uintptr_t*>(
        static_cast<std::uint8_t*>(stageResult) + 0x178);
    id value = reinterpret_cast<id>(__atomic_load_n(slot, __ATOMIC_ACQUIRE));
    if (value == nil) {
        ++libraryCreates;
        if (libraryCppThrows.load() > 0 && libraryCppThrows.fetch_sub(1) > 0) {
            throw LibraryException {};
        }
        if (libraryObjcThrows.load() > 0 && libraryObjcThrows.fetch_sub(1) > 0) {
            @throw [NSException exceptionWithName:@"LibraryException" reason:nil userInfo:nil];
        }
        if (recurseLibrary.exchange(false)) {
            id nested = yaagl::pso::getAndRetainLibrarySingleFlight(
                stageResult, device, &fakeGetAndRetainLibrary);
            [nested release];
        }
        for (unsigned index = 0; index < 2; ++index) {
            if (stageResult == libraryCycleStages[index]) {
                const unsigned bit = 1U << index;
                if ((libraryCycleEntered.fetch_or(bit) & bit) == 0) {
                    libraryCycleLatch->arriveAndWait();
                    id nested = yaagl::pso::getAndRetainLibrarySingleFlight(
                        libraryCycleStages[1 - index], device, &fakeGetAndRetainLibrary);
                    [nested release];
                }
            }
        }
        if (libraryCreatorLatch != nullptr) libraryCreatorLatch->arriveAndWait();
        if (libraryFailures.load() > 0 && libraryFailures.fetch_sub(1) > 0) {
            return nil;
        }
        id created = [[CountedLibrary alloc] init];
        std::uintptr_t expected = 0;
        const std::uintptr_t desired = reinterpret_cast<std::uintptr_t>(created);
        if (!__atomic_compare_exchange_n(
                slot, &expected, desired, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            [created release];
        }
        value = reinterpret_cast<id>(__atomic_load_n(slot, __ATOMIC_ACQUIRE));
    }
    return [value retain];
}

void releaseStageLibrary(StageStorage& stage) {
    auto* slot = reinterpret_cast<std::uintptr_t*>(stage.bytes + 0x178);
    id value = reinterpret_cast<id>(__atomic_exchange_n(slot, 0, __ATOMIC_ACQ_REL));
    [value release];
}

struct NativeKey final {
    std::uint16_t tag;
    std::uint16_t size;
    std::uint32_t value;
    std::uint64_t salt;
};
static_assert(sizeof(NativeKey) == 16);

struct Descriptor final {
    NativeKey key;
    bool graphics = false;
};

struct FakeCache final {
    std::mutex mutex;
    std::vector<NativeKey> keys;
};

std::atomic<int> stageCreates {0};
std::atomic<int> stageFailures {0};
std::atomic<bool> recurseStages {false};
std::atomic<bool> transientStageKeys {false};
std::atomic<unsigned> stageCycleEntered {0};
Descriptor* stageCycleDescriptors[2] {};
Latch* stageCycleLatch = nullptr;
Latch* stageCreatorLatch = nullptr;
int pipelineToken = 0;

bool equalKey(const NativeKey& first, const NativeKey& second) {
    return std::memcmp(&first, &second, first.size) == 0;
}

void* fakeComputeKey(void* rawDescriptor) {
    auto* key = &static_cast<Descriptor*>(rawDescriptor)->key;
    if (!transientStageKeys.load()) return key;
    auto* copy = static_cast<NativeKey*>(std::malloc(sizeof(NativeKey)));
    CHECK(copy != nullptr);
    *copy = *key;
    return copy;
}

std::uintptr_t lastIgnoredGraphicsFlag = 0;
std::uint32_t lastGraphicsDeviceFlag = 0;

void* fakeGraphicsKey(
    void* rawDescriptor, std::uintptr_t ignoredFlag, std::uint32_t deviceFlag) {
    lastIgnoredGraphicsFlag = ignoredFlag;
    lastGraphicsDeviceFlag = deviceFlag;
    return &static_cast<Descriptor*>(rawDescriptor)->key;
}

void* fakeCompile(void* rawCache, void* rawDescriptor) {
    auto* cache = static_cast<FakeCache*>(rawCache);
    auto* descriptor = static_cast<Descriptor*>(rawDescriptor);
    auto* key = static_cast<NativeKey*>(descriptor->graphics
        ? yaaglPsoCreateGraphicsStageKeyHook(descriptor, true, false)
        : yaaglPsoCreateComputeStageKeyHook(descriptor));
    NativeKey transientKey {};
    if (transientStageKeys.load() && !descriptor->graphics) {
        transientKey = *key;
        std::free(key);
        key = &transientKey;
    }
    {
        std::lock_guard lock(cache->mutex);
        for (const NativeKey& cached : cache->keys) {
            if (equalKey(cached, *key)) return &pipelineToken;
        }
    }

    ++stageCreates;
    if (recurseStages.exchange(false)) {
        void* nested = descriptor->graphics
            ? yaaglPsoCompileGraphicsStagesHook(cache, descriptor)
            : yaaglPsoCompileComputeStagesHook(cache, descriptor);
        CHECK(nested != nullptr);
    }
    for (unsigned index = 0; index < 2; ++index) {
        if (descriptor == stageCycleDescriptors[index]) {
            const unsigned bit = 1U << index;
            if ((stageCycleEntered.fetch_or(bit) & bit) == 0) {
                stageCycleLatch->arriveAndWait();
                CHECK(yaaglPsoCompileComputeStagesHook(
                    cache, stageCycleDescriptors[1 - index]) != nullptr);
            }
        }
    }
    if (stageCreatorLatch != nullptr) stageCreatorLatch->arriveAndWait();
    if (stageFailures.load() > 0 && stageFailures.fetch_sub(1) > 0) return nullptr;

    std::lock_guard lock(cache->mutex);
    for (const NativeKey& cached : cache->keys) {
        if (equalKey(cached, *key)) return &pipelineToken;
    }
    cache->keys.push_back(*key);
    return &pipelineToken;
}

void initializeHooks() {
    const void* originals[] = {
        reinterpret_cast<const void*>(&fakeCompile),
        reinterpret_cast<const void*>(&fakeCompile),
        reinterpret_cast<const void*>(&fakeComputeKey),
        reinterpret_cast<const void*>(&fakeGraphicsKey),
    };
    auto hooks = yaagl::pso::initializeStageHooks(&pipelineToken, originals);
    CHECK(hooks.compileComputeStages == &yaaglPsoCompileComputeStagesHook);
    CHECK(hooks.compileGraphicsStages == &yaaglPsoCompileGraphicsStagesHook);
}

void resetLibraryCounters() {
    libraryCreates = 0;
    gLibraryDeallocations = 0;
    libraryFailures = 0;
    libraryCppThrows = 0;
    libraryObjcThrows = 0;
    recurseLibrary = false;
    libraryCycleEntered = 0;
    libraryCycleStages[0] = nullptr;
    libraryCycleStages[1] = nullptr;
    libraryCycleLatch = nullptr;
    libraryCreatorLatch = nullptr;
}

void testOldLibraryRaceCreatesTwice() {
    resetLibraryCounters();
    StageStorage stage;
    NSObject* device = [[NSObject alloc] init];
    Latch creators(2);
    libraryCreatorLatch = &creators;
    id results[2] {};
    std::thread first([&] { results[0] = fakeGetAndRetainLibrary(&stage, device); });
    std::thread second([&] { results[1] = fakeGetAndRetainLibrary(&stage, device); });
    creators.waitForArrivals();
    creators.open();
    first.join();
    second.join();
    CHECK(libraryCreates == 2);
    CHECK(results[0] == results[1]);
    [results[0] release];
    [results[1] release];
    releaseStageLibrary(stage);
    [device release];
    CHECK(gLibraryDeallocations == 2);
}

void testLibrarySingleFlightAndOwnership() {
    resetLibraryCounters();
    StageStorage stage;
    NSObject* device = [[NSObject alloc] init];
    Latch creator(1);
    libraryCreatorLatch = &creator;
    id results[2] {};
    std::thread first([&] {
        results[0] = yaagl::pso::getAndRetainLibrarySingleFlight(
            &stage, device, &fakeGetAndRetainLibrary);
    });
    creator.waitForArrivals();
    std::thread second([&] {
        results[1] = yaagl::pso::getAndRetainLibrarySingleFlight(
            &stage, device, &fakeGetAndRetainLibrary);
    });
    creator.open();
    first.join();
    second.join();
    CHECK(libraryCreates == 1);
    CHECK(results[0] != nil && results[0] == results[1]);
    [results[0] release];
    [results[1] release];
    CHECK(gLibraryDeallocations == 0);
    releaseStageLibrary(stage);
    [device release];
    CHECK(gLibraryDeallocations == 1);
}

void testLibraryFailureRetriesOneWaiter() {
    resetLibraryCounters();
    StageStorage stage;
    NSObject* device = [[NSObject alloc] init];
    Latch firstCreator(1);
    libraryCreatorLatch = &firstCreator;
    libraryFailures = 1;
    id results[2] {};
    std::thread first([&] {
        results[0] = yaagl::pso::getAndRetainLibrarySingleFlight(
            &stage, device, &fakeGetAndRetainLibrary);
    });
    firstCreator.waitForArrivals();
    std::thread second([&] {
        results[1] = yaagl::pso::getAndRetainLibrarySingleFlight(
            &stage, device, &fakeGetAndRetainLibrary);
    });
    libraryCreatorLatch = nullptr;
    firstCreator.open();
    first.join();
    second.join();
    CHECK(results[0] == nil);
    CHECK(results[1] != nil);
    CHECK(libraryCreates == 2);
    [results[1] release];
    releaseStageLibrary(stage);
    [device release];
}

void testLibraryExceptionsPermitRetry() {
    resetLibraryCounters();
    StageStorage stage;
    NSObject* device = [[NSObject alloc] init];
    libraryCppThrows = 1;
    bool caughtCpp = false;
    try {
        (void)yaagl::pso::getAndRetainLibrarySingleFlight(
            &stage, device, &fakeGetAndRetainLibrary);
    } catch (const LibraryException&) {
        caughtCpp = true;
    }
    CHECK(caughtCpp);

    libraryObjcThrows = 1;
    NSException* caughtObjc = nil;
    @try {
        (void)yaagl::pso::getAndRetainLibrarySingleFlight(
            &stage, device, &fakeGetAndRetainLibrary);
    } @catch (NSException* exception) {
        caughtObjc = exception;
    }
    CHECK(caughtObjc != nil);

    id retried = yaagl::pso::getAndRetainLibrarySingleFlight(
        &stage, device, &fakeGetAndRetainLibrary);
    CHECK(retried != nil);
    CHECK(libraryCreates == 3);
    [retried release];
    releaseStageLibrary(stage);
    [device release];
}

void testLibraryDistinctIdentityAndReentry() {
    resetLibraryCounters();
    StageStorage firstStage;
    StageStorage secondStage;
    NSObject* firstDevice = [[NSObject alloc] init];
    NSObject* secondDevice = [[NSObject alloc] init];
    Latch creators(2);
    libraryCreatorLatch = &creators;
    id results[2] {};
    std::thread first([&] { results[0] = yaagl::pso::getAndRetainLibrarySingleFlight(
        &firstStage, firstDevice, &fakeGetAndRetainLibrary); });
    std::thread second([&] { results[1] = yaagl::pso::getAndRetainLibrarySingleFlight(
        &secondStage, secondDevice, &fakeGetAndRetainLibrary); });
    creators.waitForArrivals();
    creators.open();
    first.join();
    second.join();
    CHECK(libraryCreates == 2);
    [results[0] release];
    [results[1] release];
    releaseStageLibrary(firstStage);
    releaseStageLibrary(secondStage);

    StageStorage recursiveStage;
    libraryCreatorLatch = nullptr;
    recurseLibrary = true;
    id recursive = yaagl::pso::getAndRetainLibrarySingleFlight(
        &recursiveStage, firstDevice, &fakeGetAndRetainLibrary);
    CHECK(recursive != nil);
    [recursive release];
    releaseStageLibrary(recursiveStage);
    [firstDevice release];
    [secondDevice release];
}

void testLibraryCrossThreadCycleDoesNotDeadlock() {
    resetLibraryCounters();
    StageStorage stages[2];
    NSObject* device = [[NSObject alloc] init];
    Latch cycle(2);
    libraryCycleStages[0] = &stages[0];
    libraryCycleStages[1] = &stages[1];
    libraryCycleLatch = &cycle;
    id results[2] {};
    std::thread first([&] { results[0] = yaagl::pso::getAndRetainLibrarySingleFlight(
        &stages[0], device, &fakeGetAndRetainLibrary); });
    std::thread second([&] { results[1] = yaagl::pso::getAndRetainLibrarySingleFlight(
        &stages[1], device, &fakeGetAndRetainLibrary); });
    cycle.waitForArrivals();
    cycle.open();
    first.join();
    second.join();
    CHECK(results[0] != nil && results[1] != nil);
    [results[0] release];
    [results[1] release];
    releaseStageLibrary(stages[0]);
    releaseStageLibrary(stages[1]);
    [device release];
}

Descriptor descriptor(std::uint32_t value, bool graphics = false) {
    return {{0x51a9, sizeof(NativeKey), value, 0xabcddcba11223344ULL}, graphics};
}

void testGraphicsRawRegisterForwarding() {
    Descriptor value = descriptor(5, true);
    const std::uintptr_t rawIgnored = 0x123456789abcdef0ULL;
    CHECK(yaaglPsoCreateGraphicsStageKeyHook(&value, rawIgnored, 1) == &value.key);
    CHECK(lastIgnoredGraphicsFlag == rawIgnored);
    CHECK(lastGraphicsDeviceFlag == 1);
}

void testOldOuterRaceCreatesTwice() {
    FakeCache cache;
    Descriptor firstDescriptor = descriptor(6);
    Descriptor secondDescriptor = descriptor(6);
    stageCreates = 0;
    stageFailures = 0;
    Latch creators(2);
    stageCreatorLatch = &creators;
    std::thread first([&] { CHECK(fakeCompile(&cache, &firstDescriptor)); });
    std::thread second([&] { CHECK(fakeCompile(&cache, &secondDescriptor)); });
    creators.waitForArrivals();
    creators.open();
    first.join();
    second.join();
    CHECK(stageCreates == 2);
}

void testOuterSharedKeySingleCreator() {
    FakeCache cache;
    Descriptor firstDescriptor = descriptor(7);
    Descriptor secondDescriptor = descriptor(7);
    stageCreates = 0;
    stageFailures = 0;
    Latch creator(1);
    stageCreatorLatch = &creator;
    void* results[2] {};
    std::thread first([&] { results[0] = yaaglPsoCompileComputeStagesHook(&cache, &firstDescriptor); });
    creator.waitForArrivals();
    std::thread second([&] { results[1] = yaaglPsoCompileComputeStagesHook(&cache, &secondDescriptor); });
    creator.open();
    first.join();
    second.join();
    CHECK(results[0] != nullptr && results[1] != nullptr);
    CHECK(stageCreates == 1);
}

void testOuterCopiesTransientNativeKey() {
    FakeCache cache;
    Descriptor firstDescriptor = descriptor(14);
    Descriptor secondDescriptor = descriptor(14);
    stageCreates = 0;
    stageFailures = 0;
    transientStageKeys = true;
    Latch creator(1);
    stageCreatorLatch = &creator;
    void* results[2] {};
    std::thread first([&] { results[0] = yaaglPsoCompileComputeStagesHook(
        &cache, &firstDescriptor); });
    creator.waitForArrivals();
    std::thread second([&] { results[1] = yaaglPsoCompileComputeStagesHook(
        &cache, &secondDescriptor); });
    creator.open();
    first.join();
    second.join();
    CHECK(results[0] != nullptr && results[1] != nullptr);
    CHECK(stageCreates == 1);
    transientStageKeys = false;
    stageCreatorLatch = nullptr;
}

void testOuterDistinctKeysOverlap() {
    FakeCache cache;
    Descriptor firstDescriptor = descriptor(8);
    Descriptor secondDescriptor = descriptor(9);
    stageCreates = 0;
    stageFailures = 0;
    Latch creators(2);
    stageCreatorLatch = &creators;
    std::thread first([&] { CHECK(yaaglPsoCompileComputeStagesHook(&cache, &firstDescriptor)); });
    std::thread second([&] { CHECK(yaaglPsoCompileComputeStagesHook(&cache, &secondDescriptor)); });
    creators.waitForArrivals();
    creators.open();
    first.join();
    second.join();
    CHECK(stageCreates == 2);
}

void testOuterFailurePromotesWaiter() {
    FakeCache cache;
    Descriptor firstDescriptor = descriptor(10, true);
    Descriptor secondDescriptor = descriptor(10, true);
    stageCreates = 0;
    stageFailures = 1;
    Latch firstCreator(1);
    stageCreatorLatch = &firstCreator;
    void* results[2] {};
    std::thread first([&] { results[0] = yaaglPsoCompileGraphicsStagesHook(&cache, &firstDescriptor); });
    firstCreator.waitForArrivals();
    std::thread second([&] { results[1] = yaaglPsoCompileGraphicsStagesHook(&cache, &secondDescriptor); });
    stageCreatorLatch = nullptr;
    firstCreator.open();
    first.join();
    second.join();
    CHECK(results[0] == nullptr);
    CHECK(results[1] != nullptr);
    CHECK(stageCreates == 2);
}

void testOuterCrossThreadCycleDoesNotDeadlock() {
    FakeCache cache;
    Descriptor descriptors[] = {descriptor(12), descriptor(13)};
    stageCreates = 0;
    stageFailures = 0;
    stageCreatorLatch = nullptr;
    stageCycleEntered = 0;
    stageCycleDescriptors[0] = &descriptors[0];
    stageCycleDescriptors[1] = &descriptors[1];
    Latch cycle(2);
    stageCycleLatch = &cycle;
    void* results[2] {};
    std::thread first([&] { results[0] = yaaglPsoCompileComputeStagesHook(
        &cache, &descriptors[0]); });
    std::thread second([&] { results[1] = yaaglPsoCompileComputeStagesHook(
        &cache, &descriptors[1]); });
    cycle.waitForArrivals();
    cycle.open();
    first.join();
    second.join();
    CHECK(results[0] != nullptr && results[1] != nullptr);
    stageCycleDescriptors[0] = nullptr;
    stageCycleDescriptors[1] = nullptr;
    stageCycleLatch = nullptr;
}

void testOuterReentryDoesNotWait() {
    FakeCache cache;
    Descriptor value = descriptor(11);
    stageCreates = 0;
    stageFailures = 0;
    stageCreatorLatch = nullptr;
    recurseStages = true;
    CHECK(yaaglPsoCompileComputeStagesHook(&cache, &value) != nullptr);
    CHECK(stageCreates == 2);
}

} // namespace

int main() {
    @autoreleasepool {
        initializeHooks();
        testOldLibraryRaceCreatesTwice();
        testLibrarySingleFlightAndOwnership();
        testLibraryFailureRetriesOneWaiter();
        testLibraryExceptionsPermitRetry();
        testLibraryDistinctIdentityAndReentry();
        testLibraryCrossThreadCycleDoesNotDeadlock();
        testGraphicsRawRegisterForwarding();
        testOldOuterRaceCreatesTwice();
        testOuterSharedKeySingleCreator();
        testOuterCopiesTransientNativeKey();
        testOuterDistinctKeysOverlap();
        testOuterFailurePromotesWaiter();
        testOuterCrossThreadCycleDoesNotDeadlock();
        testOuterReentryDoesNotWait();
    }
    std::cout << "stage-cache regression tests passed\n";
    return 0;
}
