#import "cache.hpp"
#import "key.hpp"
#import "rt-key.hpp"

#import <Metal/Metal.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>

using yaagl::pso::Api;
using yaagl::pso::Cache;
using yaagl::pso::Context;
using yaagl::pso::ContextKind;
using yaagl::pso::Key;
using yaagl::pso::NativeResult;

@interface YaaglTestMeshDescriptor : MTLMeshRenderPipelineDescriptor
- (NSUInteger)colorAttachmentMappingState;
- (BOOL)isLogicOperationEnabled;
- (NSUInteger)logicOperation;
@end

@implementation YaaglTestMeshDescriptor
- (NSUInteger)colorAttachmentMappingState { return 0; }
- (BOOL)isLogicOperationEnabled { return NO; }
- (NSUInteger)logicOperation { return 0; }
@end

@interface YaaglTestFunction : NSObject {
    NSString* _name;
}
- (instancetype)initWithName:(NSString*)name;
- (NSString*)name;
- (MTLFunctionType)functionType;
@end

@implementation YaaglTestFunction
- (instancetype)initWithName:(NSString*)name {
    self = [super init];
    if (self != nil) {
        _name = [name copy];
    }
    return self;
}
- (void)dealloc {
    [_name release];
    [super dealloc];
}
- (NSString*)name { return _name; }
- (MTLFunctionType)functionType { return MTLFunctionTypeKernel; }
@end

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

struct PinnedLayoutFixture final {
    alignas(std::max_align_t) std::array<std::byte, 0x380> device {};
    alignas(std::max_align_t) std::array<std::byte, 0x40> owner {};
    alignas(std::max_align_t) std::array<std::byte, 0x50> stages {};
    alignas(std::max_align_t) std::array<std::byte, 0x180> objectStage {};
    alignas(std::max_align_t) std::array<std::byte, 0x180> meshStage {};
    alignas(std::max_align_t) std::array<std::byte, 0x180> computeStage {};

    PinnedLayoutFixture(id<MTLDevice> metalDevice, id<MTLLibrary> library) {
        const void* stagesPointer = stages.data();
        const void* objectStagePointer = objectStage.data();
        const void* meshStagePointer = meshStage.data();
        const void* computeStagePointer = computeStage.data();
        store(device, 0x40, metalDevice);
        store(owner, 0x30, stagesPointer);
        store(stages, 0x38, computeStagePointer);
        store(stages, 0x40, objectStagePointer);
        store(stages, 0x48, meshStagePointer);
        store(objectStage, 0x178, library);
        store(meshStage, 0x178, library);
        store(computeStage, 0x178, library);
    }
};

NativeResult makeState(int& creations) {
    ++creations;
    return NativeResult([[NSObject alloc] init], nil, nil);
}

void consumeThreeKeys(
    const void* device,
    const Key& first,
    const Key& second,
    const Key& third) {
    Cache cache;
    int creations = 0;
    NativeResult firstResult = cache.getOrCreate(
        device, first.bytes, first.resources, [&] { return makeState(creations); });
    NativeResult secondResult = cache.getOrCreate(
        device, second.bytes, second.resources, [&] { return makeState(creations); });
    NativeResult thirdResult = cache.getOrCreate(
        device, third.bytes, third.resources, [&] { return makeState(creations); });
    CHECK(creations == 3);
    CHECK(firstResult.state() != secondResult.state());
    CHECK(firstResult.state() != thirdResult.state());
    CHECK(secondResult.state() != thirdResult.state());
}

void testComputeKeyPreservesEmbeddedNulAndLibraryIdentity() {
    NSObject* metalDevice = [[NSObject alloc] init];
    NSObject* firstLibrary = [[NSObject alloc] init];
    NSObject* secondLibrary = [[NSObject alloc] init];
    PinnedLayoutFixture firstFixture(
        static_cast<id<MTLDevice>>(metalDevice),
        static_cast<id<MTLLibrary>>(firstLibrary));
    PinnedLayoutFixture secondFixture(
        static_cast<id<MTLDevice>>(metalDevice),
        static_cast<id<MTLLibrary>>(secondLibrary));

    const char embeddedBytes[] = {'A', 0, 'B'};
    NSString* embeddedName = [[NSString alloc]
        initWithBytes:embeddedBytes length:sizeof(embeddedBytes) encoding:NSUTF8StringEncoding];
    YaaglTestFunction* shortFunction = [[YaaglTestFunction alloc] initWithName:@"A"];
    YaaglTestFunction* embeddedFunction = [[YaaglTestFunction alloc] initWithName:embeddedName];
    MTLComputePipelineDescriptor* shortDescriptor = [[MTLComputePipelineDescriptor alloc] init];
    MTLComputePipelineDescriptor* embeddedDescriptor = [[MTLComputePipelineDescriptor alloc] init];
    shortDescriptor.computeFunction = static_cast<id<MTLFunction>>(shortFunction);
    embeddedDescriptor.computeFunction = static_cast<id<MTLFunction>>(embeddedFunction);

    const Context firstContext {ContextKind::Compute, firstFixture.owner.data(), 0, 0};
    const Context secondContext {ContextKind::Compute, secondFixture.owner.data(), 0, 0};
    Key shortKey;
    Key embeddedKey;
    Key secondLibraryKey;
    CHECK(yaagl::pso::makeKey(
        Api::Compute, firstFixture.device.data(), shortDescriptor, 0, false, firstContext, shortKey));
    CHECK(yaagl::pso::makeKey(
        Api::Compute, firstFixture.device.data(), embeddedDescriptor, 0, false, firstContext, embeddedKey));
    CHECK(yaagl::pso::makeKey(
        Api::Compute, secondFixture.device.data(), shortDescriptor, 0, false, secondContext, secondLibraryKey));
    CHECK(shortKey.bytes.size() != embeddedKey.bytes.size()
        || std::memcmp(shortKey.bytes.data(), embeddedKey.bytes.data(), shortKey.bytes.size()) != 0);
    CHECK(shortKey.bytes.size() == secondLibraryKey.bytes.size());
    CHECK(std::memcmp(
        shortKey.bytes.data(), secondLibraryKey.bytes.data(), shortKey.bytes.size()) != 0);
    [embeddedDescriptor release];
    [shortDescriptor release];
    [embeddedFunction release];
    [shortFunction release];
    [embeddedName release];
    [secondLibrary release];
    [firstLibrary release];
    [metalDevice release];
}

void testMeshRequiredThreadgroupSizes(
    id<MTLDevice> metalDevice,
    id<MTLLibrary> library,
    id<MTLFunction> objectFunction,
    id<MTLFunction> meshFunction) API_AVAILABLE(macos(26.0)) {
    PinnedLayoutFixture fixture(metalDevice, library);
    auto* baseline = [[YaaglTestMeshDescriptor alloc] init];
    auto* objectSized = [[YaaglTestMeshDescriptor alloc] init];
    auto* meshSized = [[YaaglTestMeshDescriptor alloc] init];
    for (YaaglTestMeshDescriptor* descriptor in @[baseline, objectSized, meshSized]) {
        descriptor.objectFunction = objectFunction;
        descriptor.meshFunction = meshFunction;
        descriptor.rasterizationEnabled = NO;
        descriptor.requiredThreadsPerObjectThreadgroup = MTLSizeMake(8, 1, 1);
        descriptor.requiredThreadsPerMeshThreadgroup = MTLSizeMake(8, 1, 1);
    }
    objectSized.requiredThreadsPerObjectThreadgroup = MTLSizeMake(16, 1, 1);
    meshSized.requiredThreadsPerMeshThreadgroup = MTLSizeMake(16, 1, 1);
    for (YaaglTestMeshDescriptor* descriptor in @[baseline, objectSized, meshSized]) {
        NSError* error = nil;
        id<MTLRenderPipelineState> state = [metalDevice
            newRenderPipelineStateWithMeshDescriptor:descriptor
            options:MTLPipelineOptionNone
            reflection:nil
            error:&error];
        if (state == nil) {
            std::cerr << error.localizedDescription.UTF8String << '\n';
        }
        CHECK(state != nil);
        [state release];
    }

    const Context context {
        ContextKind::Graphics,
        fixture.owner.data(),
        0,
        0,
    };
    Key baselineKey;
    Key objectSizedKey;
    Key meshSizedKey;
    CHECK(yaagl::pso::makeKey(
        Api::Mesh, fixture.device.data(), baseline, 0, false, context, baselineKey));
    CHECK(yaagl::pso::makeKey(
        Api::Mesh, fixture.device.data(), objectSized, 0, false, context, objectSizedKey));
    CHECK(yaagl::pso::makeKey(
        Api::Mesh, fixture.device.data(), meshSized, 0, false, context, meshSizedKey));
    consumeThreeKeys(fixture.device.data(), baselineKey, objectSizedKey, meshSizedKey);

    [meshSized release];
    [objectSized release];
    [baseline release];
}

void testRayTracingValidationAndRequiredThreads(
    id<MTLDevice> metalDevice,
    id<MTLLibrary> library,
    id<MTLFunction> function) API_AVAILABLE(macos(26.0)) {
    PinnedLayoutFixture fixture(metalDevice, library);
    store(fixture.device, 0x218, library);
    store(fixture.device, 0x370, function);

    auto* baseline = [[MTLComputePipelineDescriptor alloc] init];
    auto* validated = [[MTLComputePipelineDescriptor alloc] init];
    auto* threadSized = [[MTLComputePipelineDescriptor alloc] init];
    baseline.computeFunction = function;
    validated.computeFunction = function;
    threadSized.computeFunction = function;
    baseline.requiredThreadsPerThreadgroup = MTLSizeMake(8, 1, 1);
    validated.requiredThreadsPerThreadgroup = MTLSizeMake(8, 1, 1);
    threadSized.requiredThreadsPerThreadgroup = MTLSizeMake(16, 1, 1);
    validated.shaderValidation = MTLShaderValidationEnabled;
    for (MTLComputePipelineDescriptor* descriptor in @[baseline, validated, threadSized]) {
        NSError* error = nil;
        id<MTLComputePipelineState> state = [metalDevice
            newComputePipelineStateWithDescriptor:descriptor
            options:MTLPipelineOptionNone
            reflection:nil
            error:&error];
        if (state == nil) {
            std::cerr << error.localizedDescription.UTF8String << '\n';
        }
        CHECK(state != nil);
        [state release];
    }

    Key baselineKey;
    Key validatedKey;
    Key threadSizedKey;
    CHECK(yaagl::pso::makeRayTracingKey(
        fixture.device.data(), baseline, 0, false, baselineKey));
    CHECK(yaagl::pso::makeRayTracingKey(
        fixture.device.data(), validated, 0, false, validatedKey));
    CHECK(yaagl::pso::makeRayTracingKey(
        fixture.device.data(), threadSized, 0, false, threadSizedKey));
    consumeThreeKeys(fixture.device.data(), baselineKey, validatedKey, threadSizedKey);

    [threadSized release];
    [validated release];
    [baseline release];
}

void testKeyBytesPreserveInlineBoundaryAndAliasing() {
    std::array<std::uint8_t, yaagl::pso::KeyBytes::kInlineCapacity + 1> expected;
    for (std::size_t index = 0; index < expected.size(); ++index) {
        expected[index] = static_cast<std::uint8_t>(index);
    }

    yaagl::pso::KeyBytes bytes;
    bytes.append(expected.data(), yaagl::pso::KeyBytes::kInlineCapacity - 1);
    bytes.append(expected.data() + yaagl::pso::KeyBytes::kInlineCapacity - 1, 2);
    CHECK(bytes.size() == expected.size());
    CHECK(std::memcmp(bytes.data(), expected.data(), expected.size()) == 0);

    bytes.clear();
    bytes.append(expected.data(), 512);
    bytes.append(bytes.data() + 128, 256);
    CHECK(bytes.size() == 768);
    CHECK(std::memcmp(bytes.data(), expected.data(), 512) == 0);
    CHECK(std::memcmp(bytes.data() + 512, expected.data() + 128, 256) == 0);

    bytes.append(bytes.data(), 768);
    CHECK(bytes.size() == 1536);
    CHECK(std::memcmp(bytes.data(), bytes.data() + 768, 768) == 0);

    bytes.append(bytes.data() + 200, 1000);
    CHECK(bytes.size() == 2536);
    CHECK(std::memcmp(bytes.data() + 1536, bytes.data() + 200, 1000) == 0);

    bytes.clear();
    bytes.append(expected.data(), expected.size());
    CHECK(bytes.size() == expected.size());
    CHECK(std::memcmp(bytes.data(), expected.data(), expected.size()) == 0);
}

} // namespace

int main() {
    @autoreleasepool {
        testKeyBytesPreserveInlineBoundaryAndAliasing();
        testComputeKeyPreservesEmbeddedNulAndLibraryIdentity();
        if (@available(macOS 26.0, *)) {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            CHECK(device != nil);
            NSError* error = nil;
            NSString* source =
                @"#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "struct MeshVertex { float4 position [[position]]; };\n"
                "using MeshOutput = metal::mesh<MeshVertex, void, 3, 1, topology::triangle>;\n"
                "[[object]] void objectMain(mesh_grid_properties grid) {\n"
                "    grid.set_threadgroups_per_grid(uint3(1, 1, 1));\n"
                "}\n"
                "[[mesh]] void meshMain(MeshOutput output,\n"
                "    uint tid [[thread_position_in_threadgroup]]) {\n"
                "    if (tid < 3) {\n"
                "        MeshVertex meshVertex;\n"
                "        meshVertex.position = float4(0.0, 0.0, 0.0, 1.0);\n"
                "        output.set_vertex(tid, meshVertex);\n"
                "        output.set_index(tid, tid);\n"
                "    }\n"
                "    if (tid == 0) output.set_primitive_count(1);\n"
                "}\n"
                "kernel void RaygenIndirection() {}\n";
            id<MTLLibrary> library = [device
                newLibraryWithSource:source
                options:nil
                error:&error];
            if (library == nil) {
                std::cerr << error.localizedDescription.UTF8String << '\n';
            }
            CHECK(library != nil);
            CHECK(error == nil);
            id<MTLFunction> objectFunction = [library newFunctionWithName:@"objectMain"];
            id<MTLFunction> meshFunction = [library newFunctionWithName:@"meshMain"];
            id<MTLFunction> raygenFunction = [library newFunctionWithName:@"RaygenIndirection"];
            CHECK(objectFunction != nil);
            CHECK(meshFunction != nil);
            CHECK(raygenFunction != nil);

            testMeshRequiredThreadgroupSizes(
                device, library, objectFunction, meshFunction);
            testRayTracingValidationAndRequiredThreads(
                device, library, raygenFunction);

            [raygenFunction release];
            [meshFunction release];
            [objectFunction release];
            [library release];
        } else {
            CHECK(false);
        }
    }
    return 0;
}
