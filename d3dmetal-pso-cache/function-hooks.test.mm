#import "function-cache.hpp"
#import "function-hooks.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>

using yaagl::pso::ContextKind;
using yaagl::pso::FunctionCache;
using yaagl::pso::FunctionContext;
using yaagl::pso::FunctionResult;
using yaagl::pso::KeyBytes;

#define CHECK(condition) do { \
    if (!(condition)) { \
        std::cerr << __FILE__ << ':' << __LINE__ << ": check failed: " #condition << '\n'; \
        std::abort(); \
    } \
} while (false)

namespace {

template<typename T, std::size_t N>
void store(std::array<std::byte, N>& bytes, const std::size_t offset, const T& value) {
    CHECK(offset <= bytes.size() && sizeof(value) <= bytes.size() - offset);
    std::memcpy(bytes.data() + offset, &value, sizeof(value));
}

enum class Specialization : std::uint8_t {
    Tessellation,
    StreamOutput,
};

struct ExtractionFixture final {
    alignas(std::max_align_t) std::array<std::byte, 0x300> owner {};
    alignas(std::max_align_t) std::array<std::byte, 0x50> stages {};
    alignas(std::max_align_t) std::array<std::byte, 0x180> vertex {};
    alignas(std::max_align_t) std::array<std::byte, 0x180> hull {};
    alignas(std::max_align_t) std::array<std::byte, 0x180> domain {};
    alignas(std::max_align_t) std::array<std::byte, 0x180> stream {};
    Specialization specialization;

    ExtractionFixture(
        const void* ownerDevice,
        id<MTLLibrary> library,
        const Specialization requested,
        const std::uint32_t outputSize,
        const std::uint32_t maxFactorBits,
        const bool tessellationHelpers = false)
        : specialization(requested) {
        const void* stagesPointer = stages.data();
        const void* vertexPointer = vertex.data();
        store(owner, 0x8, ownerDevice);
        store(owner, 0x30, stagesPointer);
        store(stages, 0x28, vertexPointer);
        store(vertex, 0x168, std::uint32_t{1});
        store(vertex, 0x128, outputSize);

        if (requested == Specialization::Tessellation) {
            const void* hullPointer = hull.data();
            const void* domainPointer = domain.data();
            store(stages, 0x10, hullPointer);
            store(stages, 0x18, domainPointer);
            store(hull, 0x178, library);
            store(owner, 0x2b9, maxFactorBits);
            if (tessellationHelpers) {
                store(hull, 0x118, std::uint8_t{3});
            }
        } else {
            const void* streamPointer = stream.data();
            store(stages, 0x20, streamPointer);
            store(stream, 0x168, std::uint32_t{6});
            store(stream, 0x139, std::uint8_t{0});
            store(stream, 0x70, std::uint8_t{1});
            store(stream, 0x178, library);
        }
    }

    [[nodiscard]] const void* reflection() const noexcept {
        const auto* stage = specialization == Specialization::Tessellation
            ? hull.data() : stream.data();
        return stage + 0x20;
    }

    [[nodiscard]] std::uintptr_t caller() const noexcept {
        return specialization == Specialization::Tessellation ? 0x110987 : 0x111523;
    }

    [[nodiscard]] FunctionContext context() const noexcept {
        return {ContextKind::Graphics, owner.data(), stages.data()};
    }
};

MTLFunctionConstantValues* makeConstants(
    const std::uint32_t outputSize,
    const Specialization specialization,
    const std::uint32_t maxFactorBits) {
    auto* constants = [[MTLFunctionConstantValues alloc] init];
    [constants setConstantValue:&outputSize
        type:MTLDataTypeUInt
        withName:@"vertex_shader_output_size_fc"];
    if (specialization == Specialization::Tessellation) {
        const float maxFactor = std::bit_cast<float>(maxFactorBits);
        [constants setConstantValue:&maxFactor
            type:MTLDataTypeFloat
            withName:@"max_tessellation_factor_fc"];
    }
    return constants;
}

struct ProducerContext final {
    id<MTLLibrary> library;
    MTLFunctionConstantValues* constants;
    std::uintptr_t rawFlag;
    const void* reflection;
    int* calls;
};

FunctionResult createSpecializedFunctions(void* opaque) {
    auto& context = *static_cast<ProducerContext*>(opaque);
    ++*context.calls;

    NSString* name = @"constants_default";
    if ((context.rawFlag & 0xff) != 0) {
        name = @"constants_compile";
    } else if (context.reflection != nullptr) {
        const auto* reflection = static_cast<const std::byte*>(context.reflection);
        std::uint8_t kind = 0;
        std::memcpy(&kind, reflection + 0xf8, sizeof(kind));
        if (kind == 3) {
            name = @"constants_tess_helpers";
        }
    }

    NSError* error = nil;
    id<MTLFunction> function = [context.library
        newFunctionWithName:name
        constantValues:context.constants
        error:&error];
    if (function == nil) {
        std::cerr << "Metal function specialization failed: "
                  << error.localizedDescription.UTF8String << '\n';
    }
    CHECK(function != nil);
    NSMutableArray* functions = [[NSMutableArray alloc] initWithObjects:function, nil];
    [function release];
    return FunctionResult(functions, true);
}

struct Request final {
    id<MTLLibrary> library;
    ExtractionFixture& fixture;
    MTLFunctionConstantValues* constants;
    std::uintptr_t rawFlag = 0;
    std::uintptr_t callerOverride = 0;
    FunctionContext contextOverride {};
    bool overrideContext = false;
};

FunctionResult extract(FunctionCache& cache, Request& request, int& calls, bool* recognized = nullptr) {
    const FunctionContext context = request.overrideContext
        ? request.contextOverride : request.fixture.context();
    const std::uintptr_t caller = request.callerOverride != 0
        ? request.callerOverride : request.fixture.caller();
    KeyBytes key;
    const void* device = nullptr;
    const bool cacheable = yaagl::pso::makeFunctionExtractionKey(
        request.library,
        request.rawFlag,
        request.fixture.reflection(),
        request.constants,
        caller,
        context,
        key,
        device);
    if (recognized != nullptr) {
        *recognized = cacheable;
    }
    ProducerContext producer {
        request.library,
        request.constants,
        request.rawFlag,
        request.fixture.reflection(),
        &calls,
    };
    return cacheable
        ? cache.getOrCreate(device, key, request.library, &createSpecializedFunctions, &producer)
        : createSpecializedFunctions(&producer);
}

std::array<std::uint32_t, 3> runFunction(
    id<MTLDevice> device,
    id<MTLCommandQueue> queue,
    id<MTLFunction> function) {
    NSError* error = nil;
    id<MTLComputePipelineState> pipeline = [device
        newComputePipelineStateWithFunction:function error:&error];
    if (pipeline == nil) {
        std::cerr << "Metal pipeline creation failed: "
                  << error.localizedDescription.UTF8String << '\n';
    }
    CHECK(pipeline != nil);
    id<MTLBuffer> buffer = [device newBufferWithLength:sizeof(std::uint32_t) * 3
        options:MTLResourceStorageModeShared];
    CHECK(buffer != nil);
    std::memset(buffer.contents, 0, buffer.length);

    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    CHECK(command != nil && encoder != nil);
    [encoder setComputePipelineState:pipeline];
    [encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
        threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [encoder endEncoding];
    [command commit];
    [command waitUntilCompleted];
    if (command.status == MTLCommandBufferStatusError) {
        std::cerr << "Metal dispatch failed: "
                  << command.error.localizedDescription.UTF8String << '\n';
    }
    CHECK(command.status == MTLCommandBufferStatusCompleted);

    std::array<std::uint32_t, 3> output {};
    std::memcpy(output.data(), buffer.contents, sizeof(output));
    [buffer release];
    [pipeline release];
    return output;
}

id<MTLFunction> onlyFunction(const FunctionResult& result) {
    CHECK(result.functions() != nil);
    CHECK(result.functions().count == 1);
    return static_cast<id<MTLFunction>>([result.functions() objectAtIndex:0]);
}

void expectOutput(
    id<MTLDevice> device,
    id<MTLCommandQueue> queue,
    const FunctionResult& result,
    const std::uint32_t outputSize,
    const std::uint32_t factorBits,
    const std::uint32_t mode) {
    const auto output = runFunction(device, queue, onlyFunction(result));
    CHECK(output[0] == outputSize);
    CHECK(output[1] == factorBits);
    CHECK(output[2] == mode);
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
        CHECK(metalDevice != nil);
        id<MTLCommandQueue> queue = [metalDevice newCommandQueue];
        CHECK(queue != nil);

        NSString* source = @R"msl(
#include <metal_stdlib>
using namespace metal;
constant uint vertex_shader_output_size_fc [[function_constant(0)]];
constant float max_tessellation_factor_fc [[function_constant(1)]];

inline void write_constants(device uint* output, uint mode) {
    output[0] = vertex_shader_output_size_fc;
    output[1] = is_function_constant_defined(max_tessellation_factor_fc)
        ? as_type<uint>(max_tessellation_factor_fc) : 0xffffffffu;
    output[2] = mode;
}

kernel void constants_default(device uint* output [[buffer(0)]]) {
    write_constants(output, 0u);
}
kernel void constants_compile(device uint* output [[buffer(0)]]) {
    write_constants(output, 1u);
}
kernel void constants_tess_helpers(device uint* output [[buffer(0)]]) {
    write_constants(output, 2u);
}
)msl";
        MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
        options.languageVersion = MTLLanguageVersion3_1;
        NSError* error = nil;
        id<MTLLibrary> firstLibrary = [metalDevice
            newLibraryWithSource:source options:options error:&error];
        if (firstLibrary == nil) {
            std::cerr << "Metal library compilation failed: "
                      << error.localizedDescription.UTF8String << '\n';
        }
        CHECK(firstLibrary != nil);
        error = nil;
        id<MTLLibrary> secondLibrary = [metalDevice
            newLibraryWithSource:source options:options error:&error];
        if (secondLibrary == nil) {
            std::cerr << "Second Metal library compilation failed: "
                      << error.localizedDescription.UTF8String << '\n';
        }
        CHECK(secondLibrary != nil);
        CHECK(firstLibrary != secondLibrary);

        int firstDomain = 0;
        int secondDomain = 0;
        constexpr std::uint32_t firstFactor = std::bit_cast<std::uint32_t>(6.25f);
        constexpr std::uint32_t changedFactor = std::bit_cast<std::uint32_t>(-3.5f);
        FunctionCache cache;
        int calls = 0;

        ExtractionFixture firstFixture(
            &firstDomain, firstLibrary, Specialization::Tessellation, 17, firstFactor);
        ExtractionFixture equivalentFixture(
            &firstDomain, firstLibrary, Specialization::Tessellation, 17, firstFactor);
        MTLFunctionConstantValues* firstConstants = makeConstants(
            17, Specialization::Tessellation, firstFactor);
        MTLFunctionConstantValues* equivalentConstants = makeConstants(
            17, Specialization::Tessellation, firstFactor);
        Request firstRequest {firstLibrary, firstFixture, firstConstants};
        Request equivalentRequest {firstLibrary, equivalentFixture, equivalentConstants};
        FunctionResult first = extract(cache, firstRequest, calls);
        FunctionResult equivalent = extract(cache, equivalentRequest, calls);
        CHECK(calls == 1);
        CHECK(first.functions() != equivalent.functions());
        CHECK(onlyFunction(first) == onlyFunction(equivalent));
        expectOutput(metalDevice, queue, first, 17, firstFactor, 0);
        [equivalent.functions() removeAllObjects];
        FunctionResult independent = extract(cache, equivalentRequest, calls);
        CHECK(calls == 1);
        CHECK(independent.functions() != first.functions());
        expectOutput(metalDevice, queue, independent, 17, firstFactor, 0);

        ExtractionFixture sizeFixture(
            &firstDomain, firstLibrary, Specialization::Tessellation, 18, firstFactor);
        MTLFunctionConstantValues* sizeConstants = makeConstants(
            18, Specialization::Tessellation, firstFactor);
        Request sizeRequest {firstLibrary, sizeFixture, sizeConstants};
        FunctionResult changedSize = extract(cache, sizeRequest, calls);
        CHECK(calls == 2);
        expectOutput(metalDevice, queue, changedSize, 18, firstFactor, 0);

        ExtractionFixture factorFixture(
            &firstDomain, firstLibrary, Specialization::Tessellation, 17, changedFactor);
        MTLFunctionConstantValues* factorConstants = makeConstants(
            17, Specialization::Tessellation, changedFactor);
        Request factorRequest {firstLibrary, factorFixture, factorConstants};
        FunctionResult changedFloat = extract(cache, factorRequest, calls);
        CHECK(calls == 3);
        expectOutput(metalDevice, queue, changedFloat, 17, changedFactor, 0);

        ExtractionFixture streamFixture(
            &firstDomain, firstLibrary, Specialization::StreamOutput, 17, 0);
        MTLFunctionConstantValues* streamConstants = makeConstants(
            17, Specialization::StreamOutput, 0);
        Request streamRequest {firstLibrary, streamFixture, streamConstants};
        FunctionResult stream = extract(cache, streamRequest, calls);
        CHECK(calls == 4);
        expectOutput(metalDevice, queue, stream, 17, 0xffffffffu, 0);

        ExtractionFixture flagFixture(
            &firstDomain, firstLibrary, Specialization::Tessellation, 17, firstFactor);
        MTLFunctionConstantValues* flagConstants = makeConstants(
            17, Specialization::Tessellation, firstFactor);
        Request flagRequest {firstLibrary, flagFixture, flagConstants, 0x10001};
        FunctionResult changedFlag = extract(cache, flagRequest, calls);
        CHECK(calls == 5);
        expectOutput(metalDevice, queue, changedFlag, 17, firstFactor, 1);

        ExtractionFixture helperFixture(
            &firstDomain, firstLibrary, Specialization::Tessellation,
            17, firstFactor, true);
        MTLFunctionConstantValues* helperConstants = makeConstants(
            17, Specialization::Tessellation, firstFactor);
        Request helperRequest {firstLibrary, helperFixture, helperConstants};
        FunctionResult changedHelpers = extract(cache, helperRequest, calls);
        CHECK(calls == 6);
        expectOutput(metalDevice, queue, changedHelpers, 17, firstFactor, 2);

        ExtractionFixture libraryFixture(
            &firstDomain, secondLibrary, Specialization::Tessellation, 17, firstFactor);
        MTLFunctionConstantValues* libraryConstants = makeConstants(
            17, Specialization::Tessellation, firstFactor);
        Request libraryRequest {secondLibrary, libraryFixture, libraryConstants};
        FunctionResult changedLibrary = extract(cache, libraryRequest, calls);
        CHECK(calls == 7);
        expectOutput(metalDevice, queue, changedLibrary, 17, firstFactor, 0);

        ExtractionFixture deviceFixture(
            &secondDomain, firstLibrary, Specialization::Tessellation, 17, firstFactor);
        MTLFunctionConstantValues* deviceConstants = makeConstants(
            17, Specialization::Tessellation, firstFactor);
        Request deviceRequest {firstLibrary, deviceFixture, deviceConstants};
        FunctionResult changedDevice = extract(cache, deviceRequest, calls);
        CHECK(calls == 8);
        expectOutput(metalDevice, queue, changedDevice, 17, firstFactor, 0);

        bool recognized = true;
        Request rtRequest {firstLibrary, firstFixture, firstConstants};
        rtRequest.overrideContext = true;
        rtRequest.contextOverride = {ContextKind::None, firstFixture.owner.data(), firstFixture.stages.data()};
        rtRequest.callerOverride = 0x127000;
        FunctionResult rtBypassA = extract(cache, rtRequest, calls, &recognized);
        CHECK(!recognized);
        FunctionResult rtBypassB = extract(cache, rtRequest, calls, &recognized);
        CHECK(!recognized && calls == 10);
        expectOutput(metalDevice, queue, rtBypassA, 17, firstFactor, 0);
        expectOutput(metalDevice, queue, rtBypassB, 17, firstFactor, 0);

        Request unknownRequest {firstLibrary, firstFixture, firstConstants};
        unknownRequest.callerOverride = 0xdeadbeef;
        FunctionResult unknownBypass = extract(cache, unknownRequest, calls, &recognized);
        CHECK(!recognized && calls == 11);
        expectOutput(metalDevice, queue, unknownBypass, 17, firstFactor, 0);

        Request unexpectedConstants {firstLibrary, firstFixture, firstConstants};
        unexpectedConstants.callerOverride = 0x1107d5;
        FunctionResult constantsBypassA = extract(cache, unexpectedConstants, calls, &recognized);
        CHECK(!recognized);
        FunctionResult constantsBypassB = extract(cache, unexpectedConstants, calls, &recognized);
        CHECK(!recognized && calls == 13);
        expectOutput(metalDevice, queue, constantsBypassA, 17, firstFactor, 0);
        expectOutput(metalDevice, queue, constantsBypassB, 17, firstFactor, 0);

        [deviceConstants release];
        [libraryConstants release];
        [helperConstants release];
        [flagConstants release];
        [streamConstants release];
        [factorConstants release];
        [sizeConstants release];
        [equivalentConstants release];
        [firstConstants release];
        [secondLibrary release];
        [firstLibrary release];
        [options release];
        [queue release];
        [metalDevice release];
    }
    std::cout << "function hook Metal specialization proof passed\n";
    return 0;
}
