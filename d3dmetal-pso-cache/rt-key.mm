#import "rt-key.hpp"
#include "stage-cache.hpp"

#if __has_feature(objc_arc)
#error "d3dmetal-pso-cache must be compiled with Objective-C automatic reference counting disabled"
#endif

#import <objc/runtime.h>

#include <atomic>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

@interface YaaglRtFunctionMetadata : NSObject {
@public
    NSArray* libraries;
    NSData* provenance;
}
@end

@implementation YaaglRtFunctionMetadata
- (void)dealloc {
    [libraries release];
    [provenance release];
    [super dealloc];
}
@end

namespace {

using CreateFunctionOriginal = void* (*)(
    void*, void*, void*, void*, bool, bool);
using CreateCombinedOriginal = void* (*)(
    void*, void*, void*, void*, void*, bool, bool, bool);
using CreateIntersectionWrapperOriginal = id (*)(void*, bool, bool);
using GetAndRetainLibraryOriginal = id (*)(void*, id);

std::atomic<CreateFunctionOriginal> gCreateFunction {nullptr};
std::atomic<CreateCombinedOriginal> gCreateCombined {nullptr};
std::atomic<CreateIntersectionWrapperOriginal> gCreateIntersectionWrapper {nullptr};
std::atomic<GetAndRetainLibraryOriginal> gGetAndRetainLibrary {nullptr};
std::atomic<const void*> gImageBase {nullptr};
char gRtMetadataKey;

enum class FunctionRole : std::uint32_t {
    Export = 1,
    CombinedAnyHitIntersection = 2,
    IntersectionWrapper = 3,
    BuiltinRayGenIndirection = 4,
};

struct CaptureFrame final {
    CaptureFrame() noexcept : previous(current) { current = this; }
    CaptureFrame(const CaptureFrame&) = delete;
    CaptureFrame& operator=(const CaptureFrame&) = delete;

    ~CaptureFrame() {
        current = previous;
        for (id library : capturedLibraries) {
            [library release];
        }
    }

    void capture(id library) noexcept {
        if (library == nil || uncacheable) {
            return;
        }
        id retained = [library retain];
        try {
            capturedLibraries.push_back(retained);
        } catch (...) {
            [retained release];
            uncacheable = true;
        }
    }

    static thread_local CaptureFrame* current;
    CaptureFrame* previous;
    std::vector<id> capturedLibraries;
    bool uncacheable = false;
};

thread_local CaptureFrame* CaptureFrame::current = nullptr;

class ByteWriter final {
public:
    explicit ByteWriter(yaagl::pso::KeyBytes& bytes) noexcept : bytes(bytes) {}

    template<typename T>
    void pod(const T& value) {
        bytes.append(&value, sizeof(value));
    }

    void raw(const void* data, const std::size_t size) {
        bytes.append(data, size);
    }

    bool string(NSString* string) {
        if (string == nil) {
            pod(std::numeric_limits<std::uint64_t>::max());
            return true;
        }
        const char* utf8 = [string UTF8String];
        if (utf8 == nullptr) {
            return false;
        }
        const NSUInteger encodedLength = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        const auto length = static_cast<std::size_t>(encodedLength);
        const auto size = static_cast<std::uint64_t>(length);
        pod(size);
        raw(utf8, length);
        return true;
    }

    yaagl::pso::KeyBytes& bytes;
};

class ResourceArray final {
public:
    ResourceArray() : value([[NSMutableArray alloc] initWithCapacity:16]) {}
    ResourceArray(const ResourceArray&) = delete;
    ResourceArray& operator=(const ResourceArray&) = delete;
    ~ResourceArray() { [value release]; }

    NSArray* take() noexcept { return std::exchange(value, nil); }

    NSMutableArray* value;
};

template<typename T>
T load(const void* base, const std::size_t offset) {
    T value;
    std::memcpy(&value, static_cast<const std::uint8_t*>(base) + offset, sizeof(value));
    return value;
}

bool appendIdentity(ByteWriter& writer, NSMutableArray* resources, id object) {
    writer.pod(reinterpret_cast<std::uintptr_t>(object));
    if (object != nil) {
        [resources addObject:object];
    }
    return object != nil;
}

id functionFromSharedResult(void* result) noexcept {
    if (result == nullptr) {
        return nil;
    }
    void* value = *static_cast<void**>(result);
    return value == nullptr ? nil : *static_cast<id*>(value);
}

void attachMetadata(
    id function,
    CaptureFrame& frame,
    FunctionRole role,
    const bool firstFlag,
    const bool secondFlag,
    const bool thirdFlag) noexcept {
    if (function == nil || frame.uncacheable || frame.capturedLibraries.empty()) {
        return;
    }

    try {
        @try {
            NSString* name = [function name];
            const auto functionType = static_cast<std::uint64_t>([function functionType]);
            yaagl::pso::KeyBytes tupleBytes;
            ByteWriter tuple(tupleBytes);
            tuple.pod(static_cast<std::uint32_t>(role));
            tuple.pod(static_cast<std::uint8_t>(firstFlag));
            tuple.pod(static_cast<std::uint8_t>(secondFlag));
            tuple.pod(static_cast<std::uint8_t>(thirdFlag));
            if (!tuple.string(name)) {
                return;
            }
            tuple.pod(functionType);

            yaagl::pso::KeyBytes provenanceBytes;
            ByteWriter provenance(provenanceBytes);
            provenance.pod(std::uint8_t {1});
            if (!provenance.string(name)) {
                return;
            }
            provenance.pod(functionType);
            provenance.pod(static_cast<std::uint64_t>(tupleBytes.size()));
            provenance.raw(tupleBytes.data(), tupleBytes.size());

            YaaglRtFunctionMetadata* metadata = [[YaaglRtFunctionMetadata alloc] init];
            if (metadata == nil) {
                return;
            }
            @try {
                metadata->libraries = [[NSArray alloc]
                    initWithObjects:frame.capturedLibraries.data()
                    count:frame.capturedLibraries.size()];
                metadata->provenance = [[NSData alloc]
                    initWithBytes:provenanceBytes.data()
                    length:provenanceBytes.size()];
                objc_setAssociatedObject(
                    function,
                    &gRtMetadataKey,
                    metadata,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } @finally {
                [metadata release];
            }
        } @catch (...) {
            // Objective-C allocation/introspection failure: leave untagged.
        }
    } catch (...) {
        // C++ allocation failure: leave untagged. The original function and
        // its ownership are unchanged; makeRayTracingKey will bypass.
    }
}

YaaglRtFunctionMetadata* validFunctionMetadata(id<MTLFunction> function) {
    YaaglRtFunctionMetadata* metadata = (YaaglRtFunctionMetadata*)
        objc_getAssociatedObject(function, &gRtMetadataKey);
    if (metadata == nil || metadata->libraries == nil || [metadata->libraries count] == 0
        || metadata->provenance == nil) {
        return nil;
    }
    return metadata;
}

bool appendFunctionWithMetadata(
    ByteWriter& writer,
    NSMutableArray* resources,
    id<MTLFunction> function,
    YaaglRtFunctionMetadata* metadata) {
    writer.raw(metadata->provenance.bytes, metadata->provenance.length);
    writer.pod(static_cast<std::uint64_t>([metadata->libraries count]));
    for (id library in metadata->libraries) {
        writer.pod(reinterpret_cast<std::uintptr_t>(library));
        [resources addObject:library];
    }
    [resources addObject:function];
    return true;
}

bool appendFunction(
    ByteWriter& writer,
    NSMutableArray* resources,
    id<MTLFunction> function) {
    if (function == nil) {
        writer.pod(std::uint8_t {0});
        return true;
    }

    YaaglRtFunctionMetadata* metadata = validFunctionMetadata(function);
    return metadata != nil
        && appendFunctionWithMetadata(writer, resources, function, metadata);
}

bool appendComputeFunction(
    ByteWriter& writer,
    NSMutableArray* resources,
    id<MTLFunction> function,
    YaaglRtFunctionMetadata* metadata,
    id builtinLibrary) {
    if (metadata != nil) {
        return appendFunctionWithMetadata(writer, resources, function, metadata);
    }

    yaagl::pso::KeyBytes tupleBytes;
    ByteWriter tuple(tupleBytes);
    tuple.pod(static_cast<std::uint32_t>(FunctionRole::BuiltinRayGenIndirection));
    tuple.pod(std::uint8_t {0});
    tuple.pod(std::uint8_t {0});
    tuple.pod(std::uint8_t {0});
    if (!tuple.string(function.name)) {
        return false;
    }
    tuple.pod(static_cast<std::uint64_t>(function.functionType));

    writer.pod(std::uint8_t {1});
    if (!writer.string(function.name)) {
        return false;
    }
    writer.pod(static_cast<std::uint64_t>(function.functionType));
    writer.pod(static_cast<std::uint64_t>(tupleBytes.size()));
    writer.raw(tupleBytes.data(), tupleBytes.size());
    writer.pod(std::uint64_t {1});
    writer.pod(reinterpret_cast<std::uintptr_t>(builtinLibrary));
    [resources addObject:builtinLibrary];
    [resources addObject:function];
    return true;
}

bool appendFunctionArray(
    ByteWriter& writer,
    NSMutableArray* resources,
    NSArray<id<MTLFunction>>* functions) {
    writer.pod(static_cast<std::uint64_t>([functions count]));
    for (id<MTLFunction> function in functions) {
        if (!appendFunction(writer, resources, function)) {
            return false;
        }
    }
    return true;
}

bool appendLinkedFunctions(
    ByteWriter& writer,
    NSMutableArray* resources,
    MTLLinkedFunctions* linked) {
    if (linked == nil) {
        writer.pod(std::uint8_t {0});
        return true;
    }

    writer.pod(std::uint8_t {1});
    if (!appendFunctionArray(writer, resources, linked.functions)
        || !appendFunctionArray(writer, resources, linked.binaryFunctions)
        || !appendFunctionArray(writer, resources, linked.privateFunctions)) {
        return false;
    }

    NSDictionary<NSString*, NSArray<id<MTLFunction>>*>* groups = linked.groups;
    const NSUInteger groupCount = [groups count];
    writer.pod(static_cast<std::uint64_t>(groupCount));
    if (groupCount == 0) {
        return true;
    }
    NSArray<NSString*>* groupNames = [[groups allKeys]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* groupName in groupNames) {
        if (!writer.string(groupName)) {
            return false;
        }
        if (!appendFunctionArray(writer, resources, [groups objectForKey:groupName])) {
            return false;
        }
    }
    return true;
}

} // namespace

extern "C" void* yaaglPsoRtCreateFunctionHook(
    void* result,
    void* stateObject,
    void* exportSharedPtr,
    void* associations,
    const bool extractReflection,
    const bool compileFlag) {
    CaptureFrame frame;
    const auto original = gCreateFunction.load(std::memory_order_acquire);
    void* returned = original(
        result,
        stateObject,
        exportSharedPtr,
        associations,
        extractReflection,
        compileFlag);
    attachMetadata(
        functionFromSharedResult(result),
        frame,
        FunctionRole::Export,
        extractReflection,
        compileFlag,
        false);
    return returned;
}

extern "C" void* yaaglPsoRtCreateCombinedFunctionHook(
    void* result,
    void* stateObject,
    void* anyHitExportSharedPtr,
    void* intersectionExportSharedPtr,
    void* associations,
    const bool extractReflection,
    const bool compileFlag,
    const bool combinedFlag) {
    CaptureFrame frame;
    const auto original = gCreateCombined.load(std::memory_order_acquire);
    void* returned = original(
        result,
        stateObject,
        anyHitExportSharedPtr,
        intersectionExportSharedPtr,
        associations,
        extractReflection,
        compileFlag,
        combinedFlag);
    attachMetadata(
        functionFromSharedResult(result),
        frame,
        FunctionRole::CombinedAnyHitIntersection,
        extractReflection,
        compileFlag,
        combinedFlag);
    return returned;
}

extern "C" id yaaglPsoRtCreateIntersectionWrapperHook(
    void* stateObject,
    const bool extractReflection,
    const bool wrapperKind) {
    CaptureFrame frame;
    const auto original = gCreateIntersectionWrapper.load(std::memory_order_acquire);
    id function = original(stateObject, extractReflection, wrapperKind);
    attachMetadata(
        function,
        frame,
        FunctionRole::IntersectionWrapper,
        extractReflection,
        wrapperKind,
        false);
    return function;
}

extern "C" id yaaglPsoRtGetAndRetainLibraryHook(void* stageResult, id metalDevice) {
    const auto original = gGetAndRetainLibrary.load(std::memory_order_acquire);
    id library = yaagl::pso::getAndRetainLibrarySingleFlight(stageResult, metalDevice, original);
    if (CaptureFrame::current != nullptr) {
        CaptureFrame::current->capture(library);
    }
    return library;
}

namespace yaagl::pso {

RtHookEntryPoints initializeRtHooks(
    const void* imageBase,
    const void* const originalTrampolines[
        static_cast<std::uint32_t>(RtOriginalSlot::Count)]) noexcept {
    if (imageBase == nullptr || originalTrampolines == nullptr) {
        return {};
    }
    for (std::uint32_t index = 0;
         index < static_cast<std::uint32_t>(RtOriginalSlot::Count);
         ++index) {
        if (originalTrampolines[index] == nullptr) {
            return {};
        }
    }

    const void* expectedBase = nullptr;
    if (!gImageBase.compare_exchange_strong(
            expectedBase, imageBase, std::memory_order_acq_rel)
        && expectedBase != imageBase) {
        return {};
    }

    gCreateFunction.store(
        reinterpret_cast<CreateFunctionOriginal>(reinterpret_cast<std::uintptr_t>(
            originalTrampolines[
                static_cast<std::uint32_t>(RtOriginalSlot::CreateFunction)])),
        std::memory_order_release);
    gCreateCombined.store(
        reinterpret_cast<CreateCombinedOriginal>(reinterpret_cast<std::uintptr_t>(
            originalTrampolines[static_cast<std::uint32_t>(
                RtOriginalSlot::CreateCombinedAnyHitIntersectionFunction)])),
        std::memory_order_release);
    gCreateIntersectionWrapper.store(
        reinterpret_cast<CreateIntersectionWrapperOriginal>(
            reinterpret_cast<std::uintptr_t>(originalTrampolines[
                static_cast<std::uint32_t>(RtOriginalSlot::CreateIntersectionWrapperFunction)])),
        std::memory_order_release);
    gGetAndRetainLibrary.store(
        reinterpret_cast<GetAndRetainLibraryOriginal>(reinterpret_cast<std::uintptr_t>(
            originalTrampolines[
                static_cast<std::uint32_t>(RtOriginalSlot::GetAndRetainLibrary)])),
        std::memory_order_release);

    return {
        &yaaglPsoRtCreateFunctionHook,
        &yaaglPsoRtCreateCombinedFunctionHook,
        &yaaglPsoRtCreateIntersectionWrapperHook,
        &yaaglPsoRtGetAndRetainLibraryHook,
    };
}

bool makeRayTracingKey(
    const void* device,
    MTLComputePipelineDescriptor* descriptor,
    const std::uint64_t options,
    const bool reflectionRequested,
    Key& output) {
    output.reset();
    if (device == nullptr || descriptor == nil) {
        return false;
    }

    id<MTLFunction> computeFunction = descriptor.computeFunction;
    if (computeFunction == nil) {
        return false;
    }

    YaaglRtFunctionMetadata* metadata = validFunctionMetadata(computeFunction);
    id builtinLibrary = nil;
    if (metadata == nil) {
        id<MTLFunction> builtin = load<id>(device, 0x370);
        builtinLibrary = load<id>(device, 0x218);
        if (computeFunction != builtin || builtinLibrary == nil) {
            return false;
        }
    }

    ByteWriter writer(output.bytes);
    ResourceArray resources;
    if (resources.value == nil) {
        return false;
    }
    constexpr std::uint32_t formatVersion = 1;
    constexpr std::uint32_t rayTracingDomain = 0x52544b31; // "RTK1"
    writer.pod(formatVersion);
    writer.pod(Api::Compute);
    writer.pod(rayTracingDomain);
    writer.pod(options);
    writer.pod(reflectionRequested);

    // device is the intercepted helper's D3DMDevice*. Key the canonical Metal
    // objects, not the wrapper address, and retain them against address reuse.
    id metalDevice = load<id>(device, 0x40);
    if (!appendIdentity(writer, resources.value, metalDevice)) {
        output.reset();
        return false;
    }

    writer.pod(static_cast<std::uint8_t>(descriptor.supportAddingBinaryFunctions));
    writer.pod(static_cast<std::uint8_t>(descriptor.supportIndirectCommandBuffers));
    writer.pod(static_cast<std::uint8_t>(
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxTotalThreadsPerThreadgroup));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxCallStackDepth));
    if (@available(macOS 15.0, *)) {
        writer.pod(std::uint8_t {1});
        writer.pod(static_cast<std::uint64_t>(descriptor.shaderValidation));
    } else {
        writer.pod(std::uint8_t {0});
        writer.pod(std::uint64_t {0});
    }
    if (@available(macOS 26.0, *)) {
        writer.pod(std::uint8_t {1});
        const MTLSize requiredThreads = descriptor.requiredThreadsPerThreadgroup;
        writer.pod(static_cast<std::uint64_t>(requiredThreads.width));
        writer.pod(static_cast<std::uint64_t>(requiredThreads.height));
        writer.pod(static_cast<std::uint64_t>(requiredThreads.depth));
    } else {
        writer.pod(std::uint8_t {0});
        writer.pod(std::uint64_t {0});
        writer.pod(std::uint64_t {0});
        writer.pod(std::uint64_t {0});
    }

    if (!appendComputeFunction(
            writer, resources.value, computeFunction, metadata, builtinLibrary)
        || !appendLinkedFunctions(writer, resources.value, descriptor.linkedFunctions)) {
        output.reset();
        return false;
    }

    output.resources = resources.take();
    if (output.resources == nil) {
        output.reset();
        return false;
    }
    return true;
}

} // namespace yaagl::pso
