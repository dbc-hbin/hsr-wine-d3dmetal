#import "function-cache.hpp"

#import <Foundation/Foundation.h>

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>

using yaagl::pso::FunctionCache;
using yaagl::pso::FunctionResult;

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

void* operator new[](const std::size_t size) { return ::operator new(size); }
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

class Gate final {
public:
    void enterAndWait() {
        std::unique_lock lock(mutex_);
        entered_ = true;
        condition_.notify_all();
        condition_.wait(lock, [this] { return open_; });
    }

    void waitUntilEntered() {
        std::unique_lock lock(mutex_);
        condition_.wait(lock, [this] { return entered_; });
    }

    void open() {
        std::lock_guard lock(mutex_);
        open_ = true;
        condition_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable condition_;
    bool entered_ = false;
    bool open_ = false;
};

class Barrier final {
public:
    explicit Barrier(const unsigned participants) : participants_(participants) {}

    void arriveAndWait() {
        std::unique_lock lock(mutex_);
        ++arrived_;
        condition_.notify_all();
        condition_.wait(lock, [this] { return arrived_ == participants_; });
    }

private:
    const unsigned participants_;
    unsigned arrived_ = 0;
    std::mutex mutex_;
    std::condition_variable condition_;
};

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

@interface ThrowingCopyArray : NSMutableArray
@end
@implementation ThrowingCopyArray
- (NSUInteger)count { return 0; }
- (id)objectAtIndex:(NSUInteger)index { (void)index; return nil; }
- (void)insertObject:(id)object atIndex:(NSUInteger)index { (void)object; (void)index; }
- (void)removeObjectAtIndex:(NSUInteger)index { (void)index; }
- (void)replaceObjectAtIndex:(NSUInteger)index withObject:(id)object { (void)index; (void)object; }
- (id)copyWithZone:(NSZone*)zone {
    (void)zone;
    @throw [NSException exceptionWithName:NSMallocException reason:@"proof" userInfo:nil];
}
@end

@interface UnexpectedCopyArray : ThrowingCopyArray
@end
@implementation UnexpectedCopyArray
- (id)copyWithZone:(NSZone*)zone {
    (void)zone;
    @throw [NSException exceptionWithName:@"UnexpectedCopy" reason:@"proof" userInfo:nil];
}
@end

@interface ThrowingMutableCopyArray : ThrowingCopyArray
@end
@implementation ThrowingMutableCopyArray
- (id)copyWithZone:(NSZone*)zone { (void)zone; return [self retain]; }
- (id)mutableCopyWithZone:(NSZone*)zone {
    (void)zone;
    @throw [NSException exceptionWithName:NSMallocException reason:@"proof" userInfo:nil];
}
@end

namespace {

FunctionResult makeArrayWithObject(id object, const bool reusable = true) {
    NSMutableArray* array = [[NSMutableArray alloc] init];
    if (object != nil) {
        [array addObject:object];
    }
    return FunctionResult(array, reusable);
}

struct CreateContext final {
    std::atomic<int>* calls;
    id object;
    bool reusable = true;
    Gate* gate = nullptr;
};

FunctionResult createArray(void* rawContext) {
    auto& context = *static_cast<CreateContext*>(rawContext);
    context.calls->fetch_add(1, std::memory_order_relaxed);
    if (context.gate != nullptr) {
        context.gate->enterAndWait();
    }
    return makeArrayWithObject(context.object, context.reusable);
}

void testRepeatedAndConcurrentSingleFlight() {
    FunctionCache cache;
    int device = 0;
    NSObject* token = [[NSObject alloc] init];
    std::atomic<int> calls{0};
    Gate gate;
    CreateContext context{&calls, token, true, &gate};
    const std::array<std::uint8_t, 3> key{1, 2, 3};
    FunctionResult first;
    FunctionResult second;

    std::thread producer([&] {
        @autoreleasepool {
            first = cache.getOrCreate(&device, key, token, &createArray, &context);
        }
    });
    gate.waitUntilEntered();
    std::thread waiter([&] {
        @autoreleasepool {
            second = cache.getOrCreate(&device, key, token, &createArray, &context);
        }
    });
    gate.open();
    producer.join();
    waiter.join();

    FunctionResult repeated = cache.getOrCreate(&device, key, token, &createArray, &context);
    CHECK(calls.load(std::memory_order_relaxed) == 1);
    CHECK(first.functions() != nil && second.functions() != nil && repeated.functions() != nil);
    CHECK(first.functions() != second.functions());
    CHECK(second.functions() != repeated.functions());
    CHECK([first.functions() objectAtIndex:0] == token);
    CHECK([second.functions() objectAtIndex:0] == token);
    [token release];
}

void testContainersAreIndependentAndForgetReleasesCacheOwnership() {
    std::atomic<int> elementDeallocations{0};
    std::atomic<int> libraryDeallocations{0};
    FunctionResult original;
    FunctionResult firstHit;
    FunctionResult secondHit;
    {
        FunctionCache cache;
        int device = 0;
        TrackedObject* element = [[TrackedObject alloc] initWithDeallocations:&elementDeallocations];
        TrackedObject* library = [[TrackedObject alloc] initWithDeallocations:&libraryDeallocations];
        std::atomic<int> calls{0};
        CreateContext context{&calls, element};
        const std::array<std::uint8_t, 1> key{4};

        original = cache.getOrCreate(&device, key, library, &createArray, &context);
        [element release];
        [library release];
        [original.functions() removeAllObjects];
        firstHit = cache.getOrCreate(&device, key, nil, &createArray, &context);
        secondHit = cache.getOrCreate(&device, key, nil, &createArray, &context);
        CHECK(calls.load(std::memory_order_relaxed) == 1);
        CHECK(firstHit.functions() != secondHit.functions());
        CHECK([firstHit.functions() count] == 1);
        CHECK([secondHit.functions() count] == 1);
        CHECK([firstHit.functions() objectAtIndex:0] == [secondHit.functions() objectAtIndex:0]);
        [firstHit.functions() removeAllObjects];
        CHECK([secondHit.functions() count] == 1);
        CHECK(elementDeallocations.load(std::memory_order_relaxed) == 0);
        CHECK(libraryDeallocations.load(std::memory_order_relaxed) == 0);
        cache.forgetDevice(&device);
        CHECK(libraryDeallocations.load(std::memory_order_relaxed) == 1);
    }
    CHECK(libraryDeallocations.load(std::memory_order_relaxed) == 1);
    CHECK(elementDeallocations.load(std::memory_order_relaxed) == 0);
    secondHit = FunctionResult();
    CHECK(elementDeallocations.load(std::memory_order_relaxed) == 1);
}

void testKeysAndDevicesAreDistinct() {
    FunctionCache cache;
    int firstDevice = 0;
    int secondDevice = 0;
    std::atomic<int> calls{0};
    CreateContext context{&calls, nil};
    const std::array<std::uint8_t, 2> firstKey{8, 1};
    const std::array<std::uint8_t, 2> secondKey{8, 2};

    FunctionResult a = cache.getOrCreate(&firstDevice, firstKey, nil, &createArray, &context);
    FunctionResult b = cache.getOrCreate(&firstDevice, secondKey, nil, &createArray, &context);
    FunctionResult c = cache.getOrCreate(&secondDevice, firstKey, nil, &createArray, &context);
    FunctionResult hit = cache.getOrCreate(&firstDevice, firstKey, nil, &createArray, &context);
    CHECK(a.functions() != nil && b.functions() != nil && c.functions() != nil && hit.functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 3);
}

void noOpRetirementAction(const void*, const void*) {}

void testCompletedEntriesSurviveBeyondFormerLimitAndRetireTogether() {
    constexpr int entryCount = 300;
    FunctionCache cache;
    int device = 0;
    std::atomic<int> calls{0};
    std::atomic<int> elementDeallocations{0};
    std::atomic<int> libraryDeallocations{0};
    TrackedObject* firstElement = nil;

    for (int index = 0; index < entryCount; ++index) {
        TrackedObject* element = [[TrackedObject alloc]
            initWithDeallocations:&elementDeallocations];
        TrackedObject* library = [[TrackedObject alloc]
            initWithDeallocations:&libraryDeallocations];
        if (index == 0) {
            firstElement = element;
        }
        CreateContext context{&calls, element};
        const std::array<std::uint8_t, 2> key{
            static_cast<std::uint8_t>(index),
            static_cast<std::uint8_t>(index >> 8),
        };
        FunctionResult result = cache.getOrCreate(
            &device, key, library, &createArray, &context);
        CHECK(result.functions() != nil);
        [element release];
        [library release];
    }

    CHECK(calls.load(std::memory_order_relaxed) == entryCount);
    CHECK(elementDeallocations.load(std::memory_order_relaxed) == 0);
    CHECK(libraryDeallocations.load(std::memory_order_relaxed) == 0);
    {
        CreateContext context{&calls, firstElement};
        const std::array<std::uint8_t, 2> firstKey{0, 0};
        FunctionResult hit = cache.getOrCreate(
            &device, firstKey, nil, &createArray, &context);
        CHECK(hit.functions() != nil);
        CHECK([hit.functions() objectAtIndex:0] == firstElement);
        CHECK(calls.load(std::memory_order_relaxed) == entryCount);
    }

    cache.withDeviceRetired(&device, &noOpRetirementAction, nullptr);
    CHECK(elementDeallocations.load(std::memory_order_relaxed) == entryCount);
    CHECK(libraryDeallocations.load(std::memory_order_relaxed) == entryCount);
}

void testFailedPartialAndNilResultsRetry() {
    FunctionCache cache;
    int device = 0;
    std::atomic<int> calls{0};
    NSObject* token = [[NSObject alloc] init];
    CreateContext partial{&calls, token, false};
    CreateContext success{&calls, token, true};
    const std::array<std::uint8_t, 1> partialKey{20};
    const std::array<std::uint8_t, 1> nilKey{21};

    FunctionResult failed = cache.getOrCreate(&device, partialKey, nil, &createArray, &partial);
    CHECK(failed.functions() != nil && !failed.reusable());
    FunctionResult retry = cache.getOrCreate(&device, partialKey, nil, &createArray, &success);
    CHECK(retry.functions() != nil && retry.reusable());

    auto createNil = +[](void* raw) -> FunctionResult {
        static_cast<std::atomic<int>*>(raw)->fetch_add(1, std::memory_order_relaxed);
        return {};
    };
    FunctionResult empty = cache.getOrCreate(&device, nilKey, nil, createNil, &calls);
    CHECK(empty.functions() == nil);
    FunctionResult nilRetry = cache.getOrCreate(&device, nilKey, nil, &createArray, &success);
    CHECK(nilRetry.functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 4);
    [token release];
}

struct ThrowContext final {
    std::atomic<int>* calls;
    Gate* gate;
};

FunctionResult throwCpp(void* rawContext) {
    auto& context = *static_cast<ThrowContext*>(rawContext);
    context.calls->fetch_add(1, std::memory_order_relaxed);
    context.gate->enterAndWait();
    throw std::runtime_error("function extraction failed");
}

FunctionResult throwObjc(void* rawContext) {
    static_cast<std::atomic<int>*>(rawContext)->fetch_add(1, std::memory_order_relaxed);
    @throw [NSException exceptionWithName:@"FunctionExtraction" reason:@"failed" userInfo:nil];
}

void testExceptionsPropagateAndLateCallersRetry() {
    FunctionCache cache;
    int device = 0;
    const std::array<std::uint8_t, 1> cppKey{30};
    const std::array<std::uint8_t, 1> objcKey{31};
    std::atomic<int> calls{0};
    Gate gate;
    ThrowContext throwing{&calls, &gate};
    std::atomic<int> caught{0};

    auto invoke = [&] {
        @autoreleasepool {
            try {
                (void)cache.getOrCreate(&device, cppKey, nil, &throwCpp, &throwing);
            } catch (const std::runtime_error&) {
                caught.fetch_add(1, std::memory_order_relaxed);
            }
        }
    };
    std::thread producer(invoke);
    gate.waitUntilEntered();
    Gate lateCaller;
    std::thread retry([&] {
        lateCaller.enterAndWait();
        invoke();
    });
    lateCaller.waitUntilEntered();
    gate.open();
    producer.join();
    CHECK(calls.load(std::memory_order_relaxed) == 1);
    CHECK(caught.load(std::memory_order_relaxed) == 1);
    // This caller reaches the cache only after the failed flight is removed.
    // It must retry creation, not reuse the previous exception.
    lateCaller.open();
    retry.join();
    CHECK(calls.load(std::memory_order_relaxed) == 2);
    CHECK(caught.load(std::memory_order_relaxed) == 2);

    CreateContext success{&calls, nil};
    CHECK(cache.getOrCreate(&device, cppKey, nil, &createArray, &success).functions() != nil);
    @try {
        (void)cache.getOrCreate(&device, objcKey, nil, &throwObjc, &calls);
        CHECK(false);
    } @catch (NSException* exception) {
        CHECK([[exception name] isEqualToString:@"FunctionExtraction"]);
    }
    CHECK(cache.getOrCreate(&device, objcKey, nil, &createArray, &success).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 5);
}

struct RecursiveContext final {
    FunctionCache* cache;
    const void* device;
    std::atomic<int>* calls;
    std::atomic<bool> recurse{true};
    std::array<std::uint8_t, 1> key{40};
};

FunctionResult createRecursive(void* rawContext) {
    auto& context = *static_cast<RecursiveContext*>(rawContext);
    context.calls->fetch_add(1, std::memory_order_relaxed);
    if (context.recurse.exchange(false, std::memory_order_relaxed)) {
        FunctionResult nested = context.cache->getOrCreate(
            context.device, context.key, nil, &createRecursive, &context);
        CHECK(nested.functions() != nil);
    }
    return makeArrayWithObject(nil);
}

void testSameThreadRecursionBypassesWait() {
    FunctionCache cache;
    int device = 0;
    std::atomic<int> calls{0};
    RecursiveContext context{&cache, &device, &calls};
    FunctionResult result = cache.getOrCreate(
        &device, context.key, nil, &createRecursive, &context);
    CHECK(result.functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);
    CHECK(cache.getOrCreate(&device, context.key, nil, &createRecursive, &context).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);
}

struct CycleContext final {
    FunctionCache* cache;
    const void* device;
    Barrier* barrier;
    std::atomic<int>* calls;
    std::array<std::uint8_t, 1> ownKey;
    std::array<std::uint8_t, 1> peerKey;
};

FunctionResult createLeaf(void* rawCalls) {
    static_cast<std::atomic<int>*>(rawCalls)->fetch_add(1, std::memory_order_relaxed);
    return makeArrayWithObject(nil);
}

FunctionResult createCycleOuter(void* rawContext) {
    auto& context = *static_cast<CycleContext*>(rawContext);
    context.calls->fetch_add(1, std::memory_order_relaxed);
    context.barrier->arriveAndWait();
    FunctionResult nested = context.cache->getOrCreate(
        context.device, context.peerKey, nil, &createLeaf, context.calls);
    CHECK(nested.functions() != nil);
    return makeArrayWithObject(nil);
}

void testCrossThreadCycleBypassesWait() {
    FunctionCache cache;
    int device = 0;
    Barrier barrier(2);
    std::atomic<int> calls{0};
    CycleContext first{&cache, &device, &barrier, &calls, {50}, {51}};
    CycleContext second{&cache, &device, &barrier, &calls, {51}, {50}};
    FunctionResult results[2];

    std::thread a([&] {
        @autoreleasepool {
            results[0] = cache.getOrCreate(
                &device, first.ownKey, nil, &createCycleOuter, &first);
        }
    });
    std::thread b([&] {
        @autoreleasepool {
            results[1] = cache.getOrCreate(
                &device, second.ownKey, nil, &createCycleOuter, &second);
        }
    });
    a.join();
    b.join();
    CHECK(results[0].functions() != nil && results[1].functions() != nil);
    const int nativeCalls = calls.load(std::memory_order_relaxed);
    CHECK(nativeCalls >= 3 && nativeCalls <= 4);
}

struct SnapshotFailureContext final {
    std::atomic<int>* calls;
    bool failMutableCopy;
};

FunctionResult createSnapshotFailure(void* rawContext) {
    auto& context = *static_cast<SnapshotFailureContext*>(rawContext);
    context.calls->fetch_add(1, std::memory_order_relaxed);
    NSMutableArray* array = context.failMutableCopy
        ? [[ThrowingMutableCopyArray alloc] init]
        : [[ThrowingCopyArray alloc] init];
    return FunctionResult(array, true);
}

void testCppAllocationFailuresBypassWithoutDuplicateProduction() {
    FunctionCache cache;
    int device = 0;
    const std::array<std::uint8_t, 1> scopeKey{58};
    const std::array<std::uint8_t, 1> insertionKey{59};
    std::atomic<int> calls{0};
    CreateContext success{&calls, nil};

    failNextCppAllocation.store(true, std::memory_order_relaxed);
    FunctionResult uncached = cache.getOrCreate(
        &device, scopeKey, nil, &createArray, &success);
    CHECK(uncached.functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 1);
    CHECK(cache.getOrCreate(
        &device, scopeKey, nil, &createArray, &success).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);

    failNextCppAllocation.store(true, std::memory_order_relaxed);
    FunctionResult insertionBypass = cache.getOrCreate(
        &device, insertionKey, nil, &createArray, &success);
    CHECK(insertionBypass.functions() != nil);
    CHECK(!failNextCppAllocation.load(std::memory_order_relaxed));
    CHECK(calls.load(std::memory_order_relaxed) == 3);
    CHECK(cache.getOrCreate(
        &device, insertionKey, nil, &createArray, &success).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 4);
    CHECK(cache.getOrCreate(
        &device, insertionKey, nil, &createArray, &success).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 4);
}

FunctionResult createUnexpectedCopy(void* rawCalls) {
    static_cast<std::atomic<int>*>(rawCalls)->fetch_add(1, std::memory_order_relaxed);
    return FunctionResult([[UnexpectedCopyArray alloc] init], true);
}

void testUnexpectedSnapshotExceptionRemovesFlight() {
    FunctionCache cache;
    int device = 0;
    std::atomic<int> calls{0};
    const std::array<std::uint8_t, 1> key{62};
    @try {
        (void)cache.getOrCreate(&device, key, nil, &createUnexpectedCopy, &calls);
        CHECK(false);
    } @catch (NSException* exception) {
        CHECK([[exception name] isEqualToString:@"UnexpectedCopy"]);
    }
    CreateContext success{&calls, nil};
    CHECK(cache.getOrCreate(&device, key, nil, &createArray, &success).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);
}

void testSnapshotFailuresBypassWithoutDuplicateProduction() {
    FunctionCache cache;
    int device = 0;
    std::atomic<int> calls{0};
    SnapshotFailureContext snapshotFailure{&calls, false};
    const std::array<std::uint8_t, 1> firstKey{60};
    FunctionResult first = cache.getOrCreate(
        &device, firstKey, nil, &createSnapshotFailure, &snapshotFailure);
    CHECK(first.functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 1);
    CreateContext success{&calls, nil};
    CHECK(cache.getOrCreate(&device, firstKey, nil, &createArray, &success).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 2);

    SnapshotFailureContext hitFailure{&calls, true};
    const std::array<std::uint8_t, 1> secondKey{61};
    CHECK(cache.getOrCreate(
        &device, secondKey, nil, &createSnapshotFailure, &hitFailure).functions() != nil);
    CHECK(cache.getOrCreate(&device, secondKey, nil, &createArray, &success).functions() != nil);
    CHECK(calls.load(std::memory_order_relaxed) == 4);
}

} // namespace

struct HitReentryContext final {
    FunctionCache* cache;
    const void* device;
    std::array<std::uint8_t, 1> inFlightKey{68};
    std::atomic<int> nestedCalls{0};
};

@interface ReentrantMutableCopyArray : ThrowingCopyArray {
    HitReentryContext* _context;
}
- (instancetype)initWithContext:(HitReentryContext*)context;
@end

@implementation ReentrantMutableCopyArray
- (instancetype)initWithContext:(HitReentryContext*)context {
    self = [super init];
    if (self) {
        _context = context;
    }
    return self;
}
- (id)copyWithZone:(NSZone*)zone { (void)zone; return [self retain]; }
- (id)mutableCopyWithZone:(NSZone*)zone {
    (void)zone;
    CreateContext nested{&_context->nestedCalls, nil};
    FunctionResult result = _context->cache->getOrCreate(
        _context->device,
        _context->inFlightKey,
        nil,
        &createArray,
        &nested);
    return result.takeFunctions();
}
@end

struct ReentrantArrayCreateContext final {
    HitReentryContext* hitContext;
    std::atomic<int>* calls;
};

FunctionResult createReentrantMutableCopy(void* rawContext) {
    auto& context = *static_cast<ReentrantArrayCreateContext*>(rawContext);
    context.calls->fetch_add(1, std::memory_order_relaxed);
    return FunctionResult(
        [[ReentrantMutableCopyArray alloc] initWithContext:context.hitContext],
        true);
}

void testHitMutableCopyReentryBypassesCrossThreadFlight() {
    FunctionCache cache;
    int device = 0;
    HitReentryContext hitContext{&cache, &device};
    std::atomic<int> warmCalls{0};
    ReentrantArrayCreateContext warmContext{&hitContext, &warmCalls};
    const std::array<std::uint8_t, 1> hitKey{67};
    CHECK(cache.getOrCreate(
        &device, hitKey, nil, &createReentrantMutableCopy, &warmContext).functions() != nil);

    Gate producerGate;
    std::atomic<int> producerCalls{0};
    CreateContext producerContext{&producerCalls, nil, true, &producerGate};
    FunctionResult producerResult;
    std::thread producer([&] {
        @autoreleasepool {
            producerResult = cache.getOrCreate(
                &device,
                hitContext.inFlightKey,
                nil,
                &createArray,
                &producerContext);
        }
    });
    producerGate.waitUntilEntered();
    FunctionResult hit = cache.getOrCreate(
        &device, hitKey, nil, &createReentrantMutableCopy, &warmContext);
    CHECK(hit.functions() != nil);
    CHECK(hitContext.nestedCalls.load(std::memory_order_relaxed) == 1);
    producerGate.open();
    producer.join();
    CHECK(producerResult.functions() != nil);
    CHECK(producerCalls.load(std::memory_order_relaxed) == 1);
    CHECK(warmCalls.load(std::memory_order_relaxed) == 1);
}

struct RetainReentryContext final {
    FunctionCache* cache;
    const void* device;
    std::atomic<int> calls{0};
    std::atomic<bool> reenter{true};
    std::array<std::uint8_t, 1> key{69};
};

FunctionResult createRetainReentry(void* rawContext) {
    auto& context = *static_cast<RetainReentryContext*>(rawContext);
    context.calls.fetch_add(1, std::memory_order_relaxed);
    return makeArrayWithObject(nil);
}

@interface ReentrantRetainLibrary : NSObject {
    RetainReentryContext* _context;
}
- (instancetype)initWithContext:(RetainReentryContext*)context;
@end

@implementation ReentrantRetainLibrary
- (instancetype)initWithContext:(RetainReentryContext*)context {
    self = [super init];
    if (self) {
        _context = context;
    }
    return self;
}
- (id)retain {
    id retained = [super retain];
    if (_context->reenter.exchange(false, std::memory_order_relaxed)) {
        FunctionResult nested = _context->cache->getOrCreate(
            _context->device,
            _context->key,
            nil,
            &createRetainReentry,
            _context);
        CHECK(nested.functions() != nil);
    }
    return retained;
}
@end

void testLibraryRetainReentryBypassesVisibleFlight() {
    FunctionCache cache;
    int device = 0;
    RetainReentryContext context{&cache, &device};
    ReentrantRetainLibrary* library =
        [[ReentrantRetainLibrary alloc] initWithContext:&context];
    FunctionResult result = cache.getOrCreate(
        &device, context.key, library, &createRetainReentry, &context);
    CHECK(result.functions() != nil);
    CHECK(context.calls.load(std::memory_order_relaxed) == 2);
    CHECK(cache.getOrCreate(
        &device, context.key, nil, &createRetainReentry, &context).functions() != nil);
    CHECK(context.calls.load(std::memory_order_relaxed) == 2);
    [library release];
}

struct RetirementContext;

@interface ReentrantLibrary : NSObject {
    RetirementContext* _context;
}
- (instancetype)initWithContext:(RetirementContext*)context;
@end

struct RetirementContext final {
    FunctionCache* cache;
    const void* device;
    std::atomic<int> nativeCalls{0};
    std::atomic<int> deallocations{0};
    std::array<std::uint8_t, 1> key{70};
};

FunctionResult createRetirementArray(void* rawContext) {
    auto& context = *static_cast<RetirementContext*>(rawContext);
    context.nativeCalls.fetch_add(1, std::memory_order_relaxed);
    return makeArrayWithObject(nil);
}

@implementation ReentrantLibrary
- (instancetype)initWithContext:(RetirementContext*)context {
    self = [super init];
    if (self) {
        _context = context;
    }
    return self;
}
- (void)dealloc {
    _context->deallocations.fetch_add(1, std::memory_order_relaxed);
    FunctionResult result = _context->cache->getOrCreate(
        _context->device,
        _context->key,
        nil,
        &createRetirementArray,
        _context);
    CHECK(result.functions() != nil);
    [super dealloc];
}
@end

void retirementAction(const void* device, const void* rawContext) {
    auto& context = *static_cast<const RetirementContext*>(rawContext);
    FunctionResult result = context.cache->getOrCreate(
        device,
        context.key,
        nil,
        &createRetirementArray,
        const_cast<RetirementContext*>(&context));
    CHECK(result.functions() != nil);
}

void testRetirementBlocksReentrantAdmissionAndAddressReuseIsFresh() {
    FunctionCache cache;
    int device = 0;
    RetirementContext context{&cache, &device};
    ReentrantLibrary* library = [[ReentrantLibrary alloc] initWithContext:&context];
    CHECK(cache.getOrCreate(
        &device, context.key, library, &createRetirementArray, &context).functions() != nil);
    [library release];
    CHECK(context.nativeCalls.load(std::memory_order_relaxed) == 1);

    cache.withDeviceRetired(&device, &retirementAction, &context);
    CHECK(context.deallocations.load(std::memory_order_relaxed) == 1);
    CHECK(context.nativeCalls.load(std::memory_order_relaxed) == 3);

    CHECK(cache.getOrCreate(
        &device, context.key, nil, &createRetirementArray, &context).functions() != nil);
    CHECK(cache.getOrCreate(
        &device, context.key, nil, &createRetirementArray, &context).functions() != nil);
    CHECK(context.nativeCalls.load(std::memory_order_relaxed) == 4);
}

int main() {
    @autoreleasepool {
        testRepeatedAndConcurrentSingleFlight();
        testContainersAreIndependentAndForgetReleasesCacheOwnership();
        testKeysAndDevicesAreDistinct();
        testCompletedEntriesSurviveBeyondFormerLimitAndRetireTogether();
        testFailedPartialAndNilResultsRetry();
        testExceptionsPropagateAndLateCallersRetry();
        testSameThreadRecursionBypassesWait();
        testCrossThreadCycleBypassesWait();
        testCppAllocationFailuresBypassWithoutDuplicateProduction();
        testUnexpectedSnapshotExceptionRemovesFlight();
        testSnapshotFailuresBypassWithoutDuplicateProduction();
        testHitMutableCopyReentryBypassesCrossThreadFlight();
        testLibraryRetainReentryBypassesVisibleFlight();
        testRetirementBlocksReentrantAdmissionAndAddressReuseIsFresh();
    }
    std::cout << "function cache tests passed\n";
    return 0;
}
