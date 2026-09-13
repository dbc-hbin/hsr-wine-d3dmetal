#import "cache.hpp"

#import <Foundation/Foundation.h>

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using yaagl::pso::Cache;
using yaagl::pso::NativeResult;

static std::atomic<bool> failNextCppAllocation{false};

void* operator new(const std::size_t size) {
    if (failNextCppAllocation.exchange(false, std::memory_order_relaxed)) {
        throw std::bad_alloc();
    }
    if (void* allocation = std::malloc(size == 0 ? 1 : size)) {
        return allocation;
    }
    throw std::bad_alloc();
}

void* operator new[](const std::size_t size) {
    return ::operator new(size);
}

void operator delete(void* allocation) noexcept { std::free(allocation); }
void operator delete[](void* allocation) noexcept { std::free(allocation); }
void operator delete(void* allocation, std::size_t) noexcept { std::free(allocation); }
void operator delete[](void* allocation, std::size_t) noexcept { std::free(allocation); }

#define CHECK(condition) do { \
    if (!(condition)) { \
        std::cerr << __FILE__ << ':' << __LINE__ << ": check failed: " #condition << '\n'; \
        std::abort(); \
    } \
} while (false)

@interface TrackedObject : NSObject {
    std::atomic<int>* _deallocations;
}
- (instancetype)initWithDeallocations:(std::atomic<int>*)deallocations;
@end

@implementation TrackedObject
- (instancetype)initWithDeallocations:(std::atomic<int>*)deallocations {
    self = [super init];
    if (self) {
        _deallocations = deallocations;
    }
    return self;
}
- (void)dealloc {
    _deallocations->fetch_add(1, std::memory_order_relaxed);
    [super dealloc];
}
@end

@interface ReentrantResource : NSObject {
    Cache* _cache;
    const void* _device;
    std::atomic<int>* _deallocations;
}
- (instancetype)initWithCache:(Cache*)cache
                       device:(const void*)device
                deallocations:(std::atomic<int>*)deallocations;
@end

@implementation ReentrantResource
- (instancetype)initWithCache:(Cache*)cache
                       device:(const void*)device
                deallocations:(std::atomic<int>*)deallocations {
    self = [super init];
    if (self) {
        _cache = cache;
        _device = device;
        _deallocations = deallocations;
    }
    return self;
}
- (void)dealloc {
    _deallocations->fetch_add(1, std::memory_order_relaxed);
    (void)_cache->getOrCreate(_device, std::array<std::uint8_t, 1>{99}, nil, [] {
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    [super dealloc];
}
@end

class OneShotBarrier final {
public:
    explicit OneShotBarrier(const int participants) : participants_(participants) {}

    void arriveAndWait() {
        std::unique_lock lock(mutex_);
        ++arrived_;
        condition_.notify_all();
        condition_.wait(lock, [this] { return arrived_ == participants_; });
    }

private:
    const int participants_;
    int arrived_ = 0;
    std::mutex mutex_;
    std::condition_variable condition_;
};

class ProducerGate final {
public:
    void enterAndWait() {
        std::unique_lock lock(mutex_);
        entered_ = true;
        condition_.notify_all();
        condition_.wait(lock, [this] { return released_; });
    }

    void waitUntilEntered() {
        std::unique_lock lock(mutex_);
        condition_.wait(lock, [this] { return entered_; });
    }

    void release() {
        std::lock_guard lock(mutex_);
        released_ = true;
        condition_.notify_all();
    }

private:
    bool entered_ = false;
    bool released_ = false;
    std::mutex mutex_;
    std::condition_variable condition_;
};

static NativeResult makeState() {
    return NativeResult([[NSObject alloc] init], nil, nil);
}

static void testSameKeyHasOneProducer() {
    Cache cache;
    int device = 0;
    constexpr int kCallers = 8;
    const std::vector<std::uint8_t> key{1, 2, 3};
    std::atomic<int> calls{0};
    OneShotBarrier callersReady(kCallers);
    ProducerGate producer;
    std::vector<NativeResult> results(kCallers);
    std::vector<std::thread> threads;

    for (int index = 0; index < kCallers; ++index) {
        threads.emplace_back([&, index] {
            @autoreleasepool {
                callersReady.arriveAndWait();
                results[index] = cache.getOrCreate(&device, key, nil, [&] {
                    calls.fetch_add(1, std::memory_order_relaxed);
                    producer.enterAndWait();
                    return makeState();
                });
            }
        });
    }

    producer.waitUntilEntered();
    producer.release();
    for (auto& thread : threads) {
        thread.join();
    }

    CHECK(calls.load(std::memory_order_relaxed) == 1);
    for (int index = 1; index < kCallers; ++index) {
        CHECK(results[index].state() == results[0].state());
    }
}

static void testNestedSameKeyBypassesIncompleteFlight() {
    Cache cache;
    int device = 0;
    const std::array<std::uint8_t, 1> key{44};
    int calls = 0;
    id nestedState = nil;

    NativeResult outer = cache.getOrCreate(&device, key, nil, [&] {
        ++calls;
        NativeResult nested = cache.getOrCreate(&device, key, nil, [&] {
            ++calls;
            return makeState();
        });
        nestedState = nested.state();
        return makeState();
    });

    CHECK(calls == 2);
    CHECK(nestedState != nil);
    CHECK(outer.state() != nestedState);
    NativeResult hit = cache.getOrCreate(&device, key, nil, [&] {
        ++calls;
        return makeState();
    });
    CHECK(hit.state() == outer.state());
    CHECK(calls == 2);
}

static void testNestedDifferentKeyWaitsForExistingProducer() {
    Cache cache;
    int device = 0;
    const std::array<std::uint8_t, 1> outerKey{45};
    const std::array<std::uint8_t, 1> nestedKey{46};
    OneShotBarrier nestedRequest(2);
    std::atomic<int> nestedCreates{0};
    NativeResult produced;
    NativeResult nested;

    std::thread producer([&] {
        @autoreleasepool {
            produced = cache.getOrCreate(&device, nestedKey, nil, [&] {
                nestedCreates.fetch_add(1, std::memory_order_relaxed);
                nestedRequest.arriveAndWait();
                return makeState();
            });
        }
    });

    NativeResult outer = cache.getOrCreate(&device, outerKey, nil, [&] {
        nestedRequest.arriveAndWait();
        nested = cache.getOrCreate(&device, nestedKey, nil, [&] {
            nestedCreates.fetch_add(1, std::memory_order_relaxed);
            return makeState();
        });
        return makeState();
    });
    producer.join();

    CHECK(outer.state() != nil);
    CHECK(nested.state() == produced.state());
    CHECK(nestedCreates.load(std::memory_order_relaxed) == 1);
}

static void testCrossThreadDependencyCycleBypassesOneWait() {
    Cache cache;
    int device = 0;
    const std::array<std::uint8_t, 1> keys[2]{{47}, {48}};
    OneShotBarrier bothProducers(2);
    std::atomic<int> outerCreates{0};
    std::atomic<int> bypassCreates{0};
    NativeResult outer[2];
    NativeResult nested[2];
    std::thread threads[2];

    for (int index = 0; index < 2; ++index) {
        threads[index] = std::thread([&, index] {
            @autoreleasepool {
                outer[index] = cache.getOrCreate(&device, keys[index], nil, [&, index] {
                    outerCreates.fetch_add(1, std::memory_order_relaxed);
                    bothProducers.arriveAndWait();
                    nested[index] = cache.getOrCreate(
                        &device, keys[1 - index], nil, [&] {
                            bypassCreates.fetch_add(1, std::memory_order_relaxed);
                            return makeState();
                        });
                    return makeState();
                });
            }
        });
    }
    for (auto& thread : threads) {
        thread.join();
    }

    CHECK(outerCreates.load(std::memory_order_relaxed) == 2);
    CHECK(bypassCreates.load(std::memory_order_relaxed) == 1);
    CHECK(outer[0].state() != nil && outer[1].state() != nil);
    CHECK(nested[0].state() != nil && nested[1].state() != nil);
}

static void testDifferentKeysCompileConcurrently() {
    Cache cache;
    int device = 0;
    OneShotBarrier bothProducers(2);
    std::atomic<int> calls{0};
    NativeResult first;
    NativeResult second;

    std::thread a([&] {
        @autoreleasepool {
            first = cache.getOrCreate(&device, std::array<std::uint8_t, 1>{1}, nil, [&] {
                calls.fetch_add(1, std::memory_order_relaxed);
                bothProducers.arriveAndWait();
                return makeState();
            });
        }
    });
    std::thread b([&] {
        @autoreleasepool {
            second = cache.getOrCreate(&device, std::array<std::uint8_t, 1>{2}, nil, [&] {
                calls.fetch_add(1, std::memory_order_relaxed);
                bothProducers.arriveAndWait();
                return makeState();
            });
        }
    });
    a.join();
    b.join();

    CHECK(calls.load(std::memory_order_relaxed) == 2);
    CHECK(first.state() != second.state());
}

static void testErrorIsNotCachedAndRetries() {
    Cache cache;
    int device = 0;
    const std::vector<std::uint8_t> key{9};
    std::atomic<int> calls{0};

    NativeResult failed = cache.getOrCreate(&device, key, nil, [&] {
        calls.fetch_add(1, std::memory_order_relaxed);
        NSError* error = [NSError errorWithDomain:@"cache.test" code:41 userInfo:nil];
        return NativeResult(nil, nil, error);
    });
    CHECK(failed.error() != nil);
    CHECK([[failed.error() domain] isEqualToString:@"cache.test"]);
    CHECK([failed.error() code] == 41);

    NativeResult retried = cache.getOrCreate(&device, key, nil, [&] {
        calls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    });
    CHECK(retried.state() != nil);
    CHECK(retried.error() == nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);
}

static void testProducerExceptionPropagatesAndRetries() {
    Cache cache;
    int device = 0;
    const std::vector<std::uint8_t> key{7};
    std::atomic<int> calls{0};

    try {
        (void)cache.getOrCreate(&device, key, nil, [&]() -> NativeResult {
            calls.fetch_add(1, std::memory_order_relaxed);
            throw std::runtime_error("native compile failed");
        });
        CHECK(false);
    } catch (const std::runtime_error& error) {
        CHECK(std::string(error.what()) == "native compile failed");
    }

    NativeResult retry = cache.getOrCreate(&device, key, nil, [&] {
        calls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    });
    CHECK(retry.state() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);
}

static void testNilStateIsNotCached() {
    Cache cache;
    int device = 0;
    const std::vector<std::uint8_t> key{8};
    std::atomic<int> calls{0};
    NativeResult empty = cache.getOrCreate(&device, key, nil, [&] {
        calls.fetch_add(1, std::memory_order_relaxed);
        return NativeResult();
    });
    CHECK(empty.state() == nil && empty.error() == nil);
    NativeResult retry = cache.getOrCreate(&device, key, nil, [&] {
        calls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    });
    CHECK(retry.state() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);
}

static void testCacheAllocationFailuresDoNotDiscardResults() {
    Cache cache;
    int device = 0;
    const std::vector<std::uint8_t> setupKey{10};
    const yaagl::pso::CreateFunction setupCreate = [] { return makeState(); };
    failNextCppAllocation.store(true, std::memory_order_relaxed);
    NativeResult setupFallback = cache.getOrCreate(&device, setupKey, nil, setupCreate);
    CHECK(setupFallback.state() != nil);
    CHECK(!failNextCppAllocation.load(std::memory_order_relaxed));

    NativeResult warm = cache.getOrCreate(
        &device, std::array<std::uint8_t, 1>{11}, nil, [] { return makeState(); });
    CHECK(warm.state() != nil);
    const std::vector<std::uint8_t> insertionKey{12};
    std::atomic<int> insertionCalls{0};
    const yaagl::pso::CreateFunction insertionCreate = [&] {
        insertionCalls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    };
    failNextCppAllocation.store(true, std::memory_order_relaxed);
    NativeResult uncached = cache.getOrCreate(
        &device, insertionKey, nil, insertionCreate);
    CHECK(uncached.state() != nil);
    CHECK(!failNextCppAllocation.load(std::memory_order_relaxed));
    NativeResult retried = cache.getOrCreate(
        &device, insertionKey, nil, insertionCreate);
    CHECK(retried.state() != nil);
    CHECK(insertionCalls.load(std::memory_order_relaxed) == 2);
}

static void testObjectiveCExceptionPropagatesAndRetries() {
    Cache cache;
    int device = 0;
    const std::vector<std::uint8_t> key{13};
    NSException* original = [NSException exceptionWithName:@"CacheTestException"
                                                    reason:@"native producer"
                                                  userInfo:nil];
    bool caught = false;
    @try {
        (void)cache.getOrCreate(&device, key, nil, [&]() -> NativeResult {
            @throw original;
        });
    } @catch (NSException* exception) {
        caught = true;
        CHECK(exception == original);
    }
    CHECK(caught);
    NativeResult retry = cache.getOrCreate(&device, key, nil, [] { return makeState(); });
    CHECK(retry.state() != nil);
}

static void testResourceDestructionCanReenterCache() {
    Cache cache;
    int device = 0;
    std::atomic<int> deallocations{0};
    ReentrantResource* resource = [[ReentrantResource alloc]
        initWithCache:&cache device:&device deallocations:&deallocations];
    NSArray* resources = [[NSArray alloc] initWithObjects:resource, nil];
    [resource release];
    NativeResult first = cache.getOrCreate(
        &device, std::array<std::uint8_t, 1>{22}, resources,
        [] { return makeState(); });
    [resources release];

    cache.forgetDevice(&device);
    CHECK(first.state() != nil);
    CHECK(deallocations.load(std::memory_order_relaxed) == 1);
    std::atomic<int> unexpectedCreate{0};
    NativeResult reentrantHit = cache.getOrCreate(
        &device, std::array<std::uint8_t, 1>{99}, nil, [&] {
            unexpectedCreate.fetch_add(1, std::memory_order_relaxed);
            return makeState();
        });
    CHECK(reentrantHit.state() != nil);
    CHECK(unexpectedCreate.load(std::memory_order_relaxed) == 0);
}

static void testFullKeyInequality() {
    Cache cache;
    int device = 0;
    std::atomic<int> calls{0};
    NativeResult a = cache.getOrCreate(&device, std::array<std::uint8_t, 3>{4, 5, 6}, nil, [&] {
        calls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    });
    NativeResult b = cache.getOrCreate(&device, std::array<std::uint8_t, 3>{4, 5, 7}, nil, [&] {
        calls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    });
    CHECK(calls.load(std::memory_order_relaxed) == 2);
    CHECK(a.state() != b.state());
}

static void testSuccessfulEntriesRemainUntilDeviceRetirement() {
    Cache cache;
    int device = 0;
    constexpr std::uint32_t kEntryCount = 1025;
    std::atomic<int> resourceDeallocations{0};
    int firstCreates = 0;

    for (std::uint32_t index = 0; index < kEntryCount; ++index) {
        const std::array<std::uint8_t, 4> key{
            static_cast<std::uint8_t>(index),
            static_cast<std::uint8_t>(index >> 8),
            static_cast<std::uint8_t>(index >> 16),
            static_cast<std::uint8_t>(index >> 24),
        };
        TrackedObject* resource = [[TrackedObject alloc]
            initWithDeallocations:&resourceDeallocations];
        NSArray* resources = [[NSArray alloc] initWithObjects:resource, nil];
        [resource release];
        NativeResult result = cache.getOrCreate(&device, key, resources, [&] {
            if (index == 0) {
                ++firstCreates;
            }
            return makeState();
        });
        [resources release];
        CHECK(result.state() != nil);
    }
    CHECK(resourceDeallocations.load(std::memory_order_relaxed) == 0);

    const std::array<std::uint8_t, 4> firstKey{};
    NativeResult lateHit = cache.getOrCreate(&device, firstKey, nil, [&] {
        ++firstCreates;
        return makeState();
    });
    CHECK(lateHit.state() != nil);
    CHECK(firstCreates == 1);

    cache.withDeviceRetired(
        &device, [](const void*, const void*) {}, nullptr);
    CHECK(resourceDeallocations.load(std::memory_order_relaxed) == kEntryCount);
}

static void testForgetCreatesNewEpochDuringOldCompletion() {
    Cache cache;
    int device = 0;
    const std::vector<std::uint8_t> key{3, 1, 4};
    ProducerGate oldProducer;
    NativeResult oldResult;
    std::atomic<int> newCalls{0};

    std::thread oldCall([&] {
        @autoreleasepool {
            oldResult = cache.getOrCreate(&device, key, nil, [&] {
                oldProducer.enterAndWait();
                return makeState();
            });
        }
    });
    oldProducer.waitUntilEntered();
    cache.forgetDevice(&device);

    NativeResult current = cache.getOrCreate(&device, key, nil, [&] {
        newCalls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    });
    oldProducer.release();
    oldCall.join();

    CHECK(oldResult.state() != current.state());
    NativeResult hit = cache.getOrCreate(&device, key, nil, [&] {
        newCalls.fetch_add(1, std::memory_order_relaxed);
        return makeState();
    });
    CHECK(hit.state() == current.state());
    CHECK(newCalls.load(std::memory_order_relaxed) == 1);
}

static void testInputKeyStorageIsNotRetained() {
    Cache cache;
    int device = 0;
    std::vector<std::uint8_t> mutableKey {1, 2};
    NativeResult first = cache.getOrCreate(&device, mutableKey, nil, [] { return makeState(); });
    mutableKey[0] = 9;

    int duplicateCreates = 0;
    const std::array<std::uint8_t, 2> originalKey {1, 2};
    NativeResult hit = cache.getOrCreate(&device, originalKey, nil, [&] {
        ++duplicateCreates;
        return makeState();
    });
    CHECK(hit.state() == first.state());
    CHECK(duplicateCreates == 0);
}

int main() {
    @autoreleasepool {
        testSameKeyHasOneProducer();
        testNestedSameKeyBypassesIncompleteFlight();
        testNestedDifferentKeyWaitsForExistingProducer();
        testCrossThreadDependencyCycleBypassesOneWait();
        testDifferentKeysCompileConcurrently();
        testErrorIsNotCachedAndRetries();
        testProducerExceptionPropagatesAndRetries();
        testNilStateIsNotCached();
        testCacheAllocationFailuresDoNotDiscardResults();
        testObjectiveCExceptionPropagatesAndRetries();
        testResourceDestructionCanReenterCache();
        testFullKeyInequality();
        testInputKeyStorageIsNotRetained();
        testSuccessfulEntriesRemainUntilDeviceRetirement();
        testForgetCreatesNewEpochDuringOldCompletion();
    }
    std::cout << "d3dmetal PSO cache tests passed\n";
    return 0;
}
