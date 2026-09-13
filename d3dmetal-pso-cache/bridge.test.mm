#ifndef TEST_BRIDGE_SOURCE
#define TEST_BRIDGE_SOURCE "bridge.mm"
#endif

#define makeKey injectedMakeKey
#include TEST_BRIDGE_SOURCE
#undef makeKey

#include <cstdlib>
#include <iostream>
#include <new>

using DeallocationCallback = void (*)(const void*);

@interface CallbackResource : NSObject {
    const void* _context;
    DeallocationCallback _callback;
}
- (instancetype)initWithContext:(const void*)context callback:(DeallocationCallback)callback;
@end

@implementation CallbackResource
- (instancetype)initWithContext:(const void*)context callback:(DeallocationCallback)callback {
    self = [super init];
    if (self) {
        _context = context;
        _callback = callback;
    }
    return self;
}
- (void)dealloc {
    _callback(_context);
    [super dealloc];
}
@end

namespace yaagl::pso {
namespace {

enum class KeyBehavior {
    Unrecognized,
    BadAlloc,
    MallocException,
    OtherObjcException,
};

enum class ProducerBehavior {
    ReturnObject,
    ThrowCpp,
    ThrowObjc,
};

struct ProducerCppException final {};
struct DestroyCppException final {};

KeyBehavior keyBehavior = KeyBehavior::Unrecognized;
ProducerBehavior producerBehavior = ProducerBehavior::ReturnObject;
int producerCalls = 0;
int destroyCalls = 0;
NSException* keyException = nil;
NSException* producerException = nil;

#define CHECK(condition) do { \
    if (!(condition)) { \
        std::cerr << __FILE__ << ':' << __LINE__ << ": check failed: " #condition << '\n'; \
        std::abort(); \
    } \
} while (false)

id countingProducer(const void*, id, std::uint64_t, id*, NSError**) {
    ++producerCalls;
    switch (producerBehavior) {
        case ProducerBehavior::ReturnObject:
            return [[NSObject alloc] init];
        case ProducerBehavior::ThrowCpp:
            throw ProducerCppException{};
        case ProducerBehavior::ThrowObjc:
            @throw producerException;
    }
    std::abort();
}

void countingDestroy(const void* device, const void*) {
    ++destroyCalls;
    (void)runtime().cache.getOrCreate(device, std::array<std::uint8_t, 1>{100}, nil, [] {
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    runtime().cache.forgetDevice(device);
    (void)runtime().cache.getOrCreate(device, std::array<std::uint8_t, 1>{101}, nil, [] {
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
}

void throwingDestroy(const void* device, const void*) {
    ++destroyCalls;
    (void)runtime().cache.getOrCreate(device, std::array<std::uint8_t, 1>{102}, nil, [] {
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    throw DestroyCppException{};
}

void resetProducer(const ProducerBehavior behavior = ProducerBehavior::ReturnObject) {
    producerBehavior = behavior;
    producerCalls = 0;
    originalFunctions[static_cast<std::size_t>(Api::Render)] =
        reinterpret_cast<std::uintptr_t>(&countingProducer);
}

id invokeRender() {
    return createPipeline(Api::Render, nullptr, nil, 0, nullptr, nullptr);
}

void expectReturnedObjectOnce() {
    id state = invokeRender();
    CHECK(state != nil);
    CHECK(producerCalls == 1);
    [state release];
}

} // namespace

bool injectedMakeKey(
    Api,
    const void*,
    id,
    std::uint64_t,
    bool,
    const Context&,
    Key& output) {
    switch (keyBehavior) {
        case KeyBehavior::Unrecognized:
            output.reset();
            return false;
        case KeyBehavior::BadAlloc:
            throw std::bad_alloc();
        case KeyBehavior::MallocException:
            @throw [NSException exceptionWithName:NSMallocException reason:nil userInfo:nil];
        case KeyBehavior::OtherObjcException:
            @throw keyException;
    }
    std::abort();
}

namespace {

void testUnrecognizedKeyBypassesOnce() {
    keyBehavior = KeyBehavior::Unrecognized;
    resetProducer();
    expectReturnedObjectOnce();
}

void testBadAllocFallsBackOnce() {
    keyBehavior = KeyBehavior::BadAlloc;
    resetProducer();
    expectReturnedObjectOnce();
}

void testMallocExceptionFallsBackOnce() {
    keyBehavior = KeyBehavior::MallocException;
    resetProducer();
    expectReturnedObjectOnce();
}

void testOtherObjcExceptionPropagatesWithoutProducing() {
    keyBehavior = KeyBehavior::OtherObjcException;
    resetProducer();
    keyException = [[NSException alloc] initWithName:@"KeyProgrammingException" reason:nil userInfo:nil];
    NSException* caught = nil;
    @try {
        static_cast<void>(invokeRender());
    } @catch (NSException* exception) {
        caught = exception;
    }
    CHECK(caught == keyException);
    CHECK(producerCalls == 0);
    [keyException release];
    keyException = nil;
}

void testFallbackDoesNotRetryCppProducerException() {
    keyBehavior = KeyBehavior::BadAlloc;
    resetProducer(ProducerBehavior::ThrowCpp);
    bool caught = false;
    try {
        invokeRender();
    } catch (const ProducerCppException&) {
        caught = true;
    }
    CHECK(caught);
    CHECK(producerCalls == 1);
}

void testFallbackDoesNotRetryObjcProducerException() {
    keyBehavior = KeyBehavior::MallocException;
    resetProducer(ProducerBehavior::ThrowObjc);
    producerException = [[NSException alloc] initWithName:@"ProducerException" reason:nil userInfo:nil];
    NSException* caught = nil;
    @try {
        static_cast<void>(invokeRender());
    } @catch (NSException* exception) {
        caught = exception;
    }
    CHECK(caught == producerException);
    CHECK(producerCalls == 1);
    [producerException release];
    producerException = nil;
}

void testDestroyRetirementBlocksReentryAndAllowsAddressReuse() {
    int device = 0;
    CallbackResource* resource = [[CallbackResource alloc]
        initWithContext:&device callback:[](const void* context) {
            (void)runtime().cache.getOrCreate(context, std::array<std::uint8_t, 1>{99}, nil, [] {
                return NativeResult([[NSObject alloc] init], nil, nil);
            });
        }];
    NSArray* resources = [[NSArray alloc] initWithObjects:resource, nil];
    [resource release];
    NativeResult seeded = runtime().cache.getOrCreate(&device, std::array<std::uint8_t, 1>{98}, resources, [] {
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    [resources release];
    CHECK(seeded.state() != nil);

    destroyCalls = 0;
    originalFunctions[static_cast<std::size_t>(layout::Hook::DestroyDevice)] =
        reinterpret_cast<std::uintptr_t>(&countingDestroy);
    destroyDevice(&device, nullptr);
    CHECK(destroyCalls == 1);

    int creates = 0;
    NativeResult afterDestroy = runtime().cache.getOrCreate(&device, std::array<std::uint8_t, 1>{99}, nil, [&] {
        ++creates;
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    NativeResult reusedAddress = runtime().cache.getOrCreate(&device, std::array<std::uint8_t, 1>{99}, nil, [&] {
        ++creates;
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    CHECK(afterDestroy.state() != nil);
    CHECK(reusedAddress.state() == afterDestroy.state());
    CHECK(creates == 1);

    int callbackKeyCreates = 0;
    NativeResult callbackKey = runtime().cache.getOrCreate(&device, std::array<std::uint8_t, 1>{100}, nil, [&] {
        ++callbackKeyCreates;
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    CHECK(callbackKey.state() != nil);
    CHECK(callbackKeyCreates == 1);

    int postForgetKeyCreates = 0;
    NativeResult postForgetKey = runtime().cache.getOrCreate(&device, std::array<std::uint8_t, 1>{101}, nil, [&] {
        ++postForgetKeyCreates;
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    CHECK(postForgetKey.state() != nil);
    CHECK(postForgetKeyCreates == 1);
    runtime().cache.forgetDevice(&device);
}

void testDestroyExceptionClearsRetirement() {
    int device = 0;
    destroyCalls = 0;
    originalFunctions[static_cast<std::size_t>(layout::Hook::DestroyDevice)] =
        reinterpret_cast<std::uintptr_t>(&throwingDestroy);
    bool caught = false;
    try {
        destroyDevice(&device, nullptr);
    } catch (const DestroyCppException&) {
        caught = true;
    }
    CHECK(caught);
    CHECK(destroyCalls == 1);

    int creates = 0;
    NativeResult afterException = runtime().cache.getOrCreate(&device, std::array<std::uint8_t, 1>{102}, nil, [&] {
        ++creates;
        return NativeResult([[NSObject alloc] init], nil, nil);
    });
    CHECK(afterException.state() != nil);
    CHECK(creates == 1);
    runtime().cache.forgetDevice(&device);
}

} // namespace
} // namespace yaagl::pso

int main() {
    @autoreleasepool {
        yaagl::pso::testUnrecognizedKeyBypassesOnce();
        yaagl::pso::testBadAllocFallsBackOnce();
        yaagl::pso::testMallocExceptionFallsBackOnce();
        yaagl::pso::testOtherObjcExceptionPropagatesWithoutProducing();
        yaagl::pso::testFallbackDoesNotRetryCppProducerException();
        yaagl::pso::testFallbackDoesNotRetryObjcProducerException();
        yaagl::pso::testDestroyRetirementBlocksReentryAndAllowsAddressReuse();
        yaagl::pso::testDestroyExceptionClearsRetirement();
    }
    return 0;
}
