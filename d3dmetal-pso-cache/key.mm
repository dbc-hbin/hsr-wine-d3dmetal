#import "key.hpp"

#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <array>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include <utility>

#include "rt-key.hpp"

#if __has_feature(objc_arc)
#error "d3dmetal-pso-cache must be compiled with Objective-C automatic reference counting disabled"
#endif

namespace yaagl::pso {

void KeyBytes::append(const void* data, const std::size_t size) {
    if (size == 0) {
        return;
    }
    if (size > std::numeric_limits<std::size_t>::max() - size_) {
        throw std::length_error("pipeline key exceeds addressable size");
    }

    const std::size_t oldSize = size_;
    const std::size_t newSize = oldSize + size;
    const auto* source = static_cast<const std::uint8_t*>(data);
    const auto* current = this->data();
    const std::uintptr_t sourceAddress = reinterpret_cast<std::uintptr_t>(source);
    const std::uintptr_t currentAddress = reinterpret_cast<std::uintptr_t>(current);
    const bool aliases = sourceAddress >= currentAddress
        && sourceAddress - currentAddress <= oldSize
        && size <= oldSize - (sourceAddress - currentAddress);
    const std::size_t sourceOffset = aliases ? sourceAddress - currentAddress : 0;

    if (newSize <= kInlineCapacity) {
        std::memmove(inline_.data() + oldSize, source, size);
        size_ = newSize;
        return;
    }

    const bool firstSpill = overflow_.empty();
    overflow_.resize(newSize);
    if (firstSpill) {
        std::memcpy(overflow_.data(), inline_.data(), oldSize);
    }
    if (aliases) {
        std::memmove(
            overflow_.data() + oldSize,
            overflow_.data() + sourceOffset,
            size);
    } else {
        std::memcpy(overflow_.data() + oldSize, source, size);
    }
    size_ = newSize;
}

Key::~Key() {
    [resources release];
}

void Key::reset() noexcept {
    bytes.clear();
    [resources release];
    resources = nil;
}

namespace {

constexpr std::uint32_t kKeyFormatVersion = 1;
constexpr std::uint32_t kNativePipelineDomain = 0x4e504b31; // "NPK1"
constexpr std::size_t kGraphicsStagesOffset = 0x30;
constexpr std::size_t kComputeStagesOffset = 0x30;
constexpr std::size_t kStageLibraryOffset = 0x178;
constexpr std::size_t kVertexOutputSizeOffset = 0x128;

enum class ConstantKind : std::uint32_t {
    Tessellation,
    StreamOutput,
};

enum class Role : std::uint32_t {
    Vertex,
    Fragment,
    VertexPrivate,
    Mesh,
    Object,
    ObjectPrivate,
    MeshPrivate,
    FragmentPrivate,
    Compute,
};

class ResourceArray final {
public:
    ResourceArray() : value_([[NSMutableArray alloc] initWithCapacity:8]) {}
    ResourceArray(const ResourceArray&) = delete;
    ResourceArray& operator=(const ResourceArray&) = delete;
    ~ResourceArray() { [value_ release]; }

    NSMutableArray* get() const noexcept { return value_; }
    NSArray* take() noexcept { return std::exchange(value_, nil); }

private:
    NSMutableArray* value_;
};

class Writer final {
public:
    Writer(KeyBytes& bytes, NSMutableArray* resources)
        : bytes_(bytes), resources_(resources) {}

    template<typename T>
    void pod(const T& value) {
        static_assert(std::is_trivially_copyable_v<T>);
        bytes_.append(&value, sizeof(value));
    }

    void raw(const void* data, const std::size_t size) {
        bytes_.append(data, size);
    }

    bool string(NSString* value) {
        if (value == nil) {
            return false;
        }
        const char* utf8 = [value UTF8String];
        if (utf8 == nullptr) {
            return false;
        }
        const std::size_t size = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (size > std::numeric_limits<std::uint32_t>::max()) {
            return false;
        }
        pod(static_cast<std::uint32_t>(size));
        raw(utf8, size);
        return true;
    }

    bool identity(id object) {
        const std::uintptr_t address = reinterpret_cast<std::uintptr_t>(object);
        pod(address);
        if (object == nil) {
            return false;
        }
        [resources_ addObject:object];
        return true;
    }

private:
    KeyBytes& bytes_;
    NSMutableArray* resources_;
};

template<typename T>
T load(const void* base, const std::size_t offset) {
    T value;
    std::memcpy(&value, static_cast<const std::uint8_t*>(base) + offset, sizeof(value));
    return value;
}

struct GraphicsProvenance final {
    const void* owner;
    const void* stages;
    Writer& writer;
    const void* stageAt(const std::size_t offset) const {
        return load<const void*>(stages, offset);
    }

    bool stageTable() const {
        constexpr std::array<std::size_t, 10> stageOffsets {
            0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48,
        };
        writer.pod(static_cast<std::uint32_t>(stageOffsets.size()));
        for (const std::size_t offset : stageOffsets) {
            const void* stage = stageAt(offset);
            writer.pod(static_cast<std::uint32_t>(offset));
            writer.pod(stage != nullptr);
            if (stage == nullptr) {
                continue;
            }
            id library = load<id>(stage, kStageLibraryOffset);
            writer.identity(library); // Some unused StageResults have no loaded library.
        }
        return true;
    }

    bool functionConstants() const {
        const void* hullStage = stageAt(0x10);
        const void* domainStage = stageAt(0x18);
        const bool tessellation = hullStage != nullptr && domainStage != nullptr;
        writer.pod(ConstantKind::Tessellation);
        writer.pod(tessellation);
        if (tessellation) {
            const void* vertexStage = stageAt(0x28);
            if (vertexStage == nullptr) {
                return false;
            }
            writer.pod(load<std::uint32_t>(vertexStage, kVertexOutputSizeOffset));
            writer.pod(load<std::uint32_t>(owner, 0x2b9));
        }

        const void* streamOutputStage = stageAt(0x20);
        const bool streamOutput = streamOutputStage != nullptr
            && load<std::uint32_t>(streamOutputStage, 0x168) == 6
            && load<std::uint8_t>(streamOutputStage, 0x139) == 0
            && load<std::uint8_t>(streamOutputStage, 0x70) == 1;
        writer.pod(ConstantKind::StreamOutput);
        writer.pod(streamOutput);
        if (streamOutput) {
            const void* vertexStage = stageAt(0x28);
            if (vertexStage == nullptr) {
                return false;
            }
            writer.pod(load<std::uint32_t>(vertexStage, kVertexOutputSizeOffset));
        }
        return true;
    }

    bool function(const Role role, id<MTLFunction> value) const {
        writer.pod(role);
        writer.pod(value != nil);
        if (value == nil) {
            return true;
        }
        writer.pod(static_cast<std::uint64_t>(value.functionType));
        return writer.string(value.name);
    }

    bool functions(const Role role, NSArray<id<MTLFunction>>* values) const {
        const NSUInteger valueCount = values.count;
        if (valueCount > std::numeric_limits<std::uint32_t>::max()) {
            return false;
        }
        const auto count = static_cast<std::uint32_t>(valueCount);
        writer.pod(count);
        for (id<MTLFunction> function : values) {
            if (!this->function(role, function)) {
                return false;
            }
        }
        return true;
    }

    bool linked(const Role role, MTLLinkedFunctions* linked) const {
        // D3DMetal 4b2 populates only privateFunctions on these descriptors.
        // Bypass rather than alias an unexpected linked-function shape.
        if (linked.functions.count != 0 || linked.binaryFunctions.count != 0
            || linked.groups.count != 0) {
            return false;
        }
        return functions(role, linked.privateFunctions);
    }

};

void appendColorAttachment(Writer& writer, MTLRenderPipelineColorAttachmentDescriptor* attachment) {
    writer.pod(static_cast<std::uint64_t>(attachment.pixelFormat));
    writer.pod(static_cast<bool>(attachment.blendingEnabled));
    writer.pod(static_cast<std::uint64_t>(attachment.sourceRGBBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.destinationRGBBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.rgbBlendOperation));
    writer.pod(static_cast<std::uint64_t>(attachment.sourceAlphaBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.destinationAlphaBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.alphaBlendOperation));
    writer.pod(static_cast<std::uint64_t>(attachment.writeMask));
}

bool appendColorMappingState(Writer& writer, id descriptor) {
    SEL selector = sel_registerName("colorAttachmentMappingState");
    const bool available = [descriptor respondsToSelector:selector];
    writer.pod(available);
    if (!available) {
        return false;
    }
    using Getter = NSUInteger (*)(id, SEL);
    const auto getter = reinterpret_cast<Getter>(objc_msgSend);
    writer.pod(static_cast<std::uint64_t>(getter(descriptor, selector)));
    return true;
}

bool appendLogicOperationState(Writer& writer, id descriptor) {
    SEL enabledSelector = sel_registerName("isLogicOperationEnabled");
    SEL operationSelector = sel_registerName("logicOperation");
    const bool available = [descriptor respondsToSelector:enabledSelector]
        && [descriptor respondsToSelector:operationSelector];
    writer.pod(available);
    if (!available) {
        return false;
    }

    using EnabledGetter = BOOL (*)(id, SEL);
    using OperationGetter = NSUInteger (*)(id, SEL);
    const auto enabledGetter = reinterpret_cast<EnabledGetter>(objc_msgSend);
    const auto operationGetter = reinterpret_cast<OperationGetter>(objc_msgSend);
    const bool enabled = enabledGetter(descriptor, enabledSelector);
    const NSUInteger operation = operationGetter(descriptor, operationSelector);
    writer.pod(enabled);
    writer.pod(static_cast<std::uint64_t>(enabled ? operation : 0));
    return true;
}

void appendRenderState(Writer& writer, MTLRenderPipelineDescriptor* descriptor) {
    writer.pod(static_cast<std::uint64_t>(descriptor.rasterSampleCount));
    writer.pod(static_cast<bool>(descriptor.alphaToCoverageEnabled));
    writer.pod(static_cast<bool>(descriptor.alphaToOneEnabled));
    writer.pod(static_cast<bool>(descriptor.rasterizationEnabled));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxVertexAmplificationCount));
    writer.pod(static_cast<std::uint64_t>(descriptor.depthAttachmentPixelFormat));
    writer.pod(static_cast<std::uint64_t>(descriptor.stencilAttachmentPixelFormat));
    writer.pod(static_cast<std::uint64_t>(descriptor.inputPrimitiveTopology));
    writer.pod(static_cast<std::uint64_t>(descriptor.tessellationPartitionMode));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxTessellationFactor));
    writer.pod(static_cast<bool>(descriptor.tessellationFactorScaleEnabled));
    writer.pod(static_cast<std::uint64_t>(descriptor.tessellationFactorFormat));
    writer.pod(static_cast<std::uint64_t>(descriptor.tessellationControlPointIndexType));
    writer.pod(static_cast<std::uint64_t>(descriptor.tessellationFactorStepFunction));
    writer.pod(static_cast<std::uint64_t>(descriptor.tessellationOutputWindingOrder));
    writer.pod(static_cast<bool>(descriptor.supportIndirectCommandBuffers));
    writer.pod(static_cast<bool>(descriptor.supportAddingVertexBinaryFunctions));
    writer.pod(static_cast<bool>(descriptor.supportAddingFragmentBinaryFunctions));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxVertexCallStackDepth));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxFragmentCallStackDepth));
    if (@available(macOS 15.0, *)) {
        writer.pod(true);
        writer.pod(static_cast<std::uint64_t>(descriptor.shaderValidation));
    } else {
        writer.pod(false);
        writer.pod(std::uint64_t {0});
    }
    for (NSUInteger index = 0; index < 8; ++index) {
        appendColorAttachment(writer, descriptor.colorAttachments[index]);
    }
}

bool appendLegacy(
    Writer& writer,
    const GraphicsProvenance& provenance,
    MTLRenderPipelineDescriptor* descriptor) {
    appendRenderState(writer, descriptor);
    return appendColorMappingState(writer, descriptor)
        && appendLogicOperationState(writer, descriptor)
        && provenance.function(Role::Vertex, descriptor.vertexFunction)
        && provenance.function(Role::Fragment, descriptor.fragmentFunction)
        && provenance.linked(Role::VertexPrivate, descriptor.vertexLinkedFunctions)
        && provenance.linked(Role::FragmentPrivate, descriptor.fragmentLinkedFunctions);
}

bool appendMesh(
    Writer& writer,
    const GraphicsProvenance& provenance,
    MTLMeshRenderPipelineDescriptor* descriptor) {
    writer.pod(static_cast<std::uint64_t>(descriptor.maxTotalThreadsPerObjectThreadgroup));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxTotalThreadsPerMeshThreadgroup));
    writer.pod(static_cast<bool>(descriptor.objectThreadgroupSizeIsMultipleOfThreadExecutionWidth));
    writer.pod(static_cast<bool>(descriptor.meshThreadgroupSizeIsMultipleOfThreadExecutionWidth));
    writer.pod(static_cast<std::uint64_t>(descriptor.payloadMemoryLength));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxTotalThreadgroupsPerMeshGrid));
    writer.pod(static_cast<std::uint64_t>(descriptor.rasterSampleCount));
    writer.pod(static_cast<bool>(descriptor.alphaToCoverageEnabled));
    writer.pod(static_cast<bool>(descriptor.alphaToOneEnabled));
    writer.pod(static_cast<bool>(descriptor.rasterizationEnabled));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxVertexAmplificationCount));
    writer.pod(static_cast<std::uint64_t>(descriptor.depthAttachmentPixelFormat));
    writer.pod(static_cast<std::uint64_t>(descriptor.stencilAttachmentPixelFormat));
    writer.pod(static_cast<bool>(descriptor.supportIndirectCommandBuffers));
    if (@available(macOS 15.0, *)) {
        writer.pod(true);
        writer.pod(static_cast<std::uint64_t>(descriptor.shaderValidation));
    } else {
        writer.pod(false);
        writer.pod(std::uint64_t {0});
    }
    if (@available(macOS 26.0, *)) {
        writer.pod(true);
        const MTLSize objectThreads = descriptor.requiredThreadsPerObjectThreadgroup;
        writer.pod(static_cast<std::uint64_t>(objectThreads.width));
        writer.pod(static_cast<std::uint64_t>(objectThreads.height));
        writer.pod(static_cast<std::uint64_t>(objectThreads.depth));
        const MTLSize meshThreads = descriptor.requiredThreadsPerMeshThreadgroup;
        writer.pod(static_cast<std::uint64_t>(meshThreads.width));
        writer.pod(static_cast<std::uint64_t>(meshThreads.height));
        writer.pod(static_cast<std::uint64_t>(meshThreads.depth));
    } else {
        writer.pod(false);
        writer.pod(std::uint64_t {0});
        writer.pod(std::uint64_t {0});
        writer.pod(std::uint64_t {0});
        writer.pod(std::uint64_t {0});
        writer.pod(std::uint64_t {0});
        writer.pod(std::uint64_t {0});
    }
    for (NSUInteger index = 0; index < 8; ++index) {
        appendColorAttachment(writer, descriptor.colorAttachments[index]);
    }
    return appendColorMappingState(writer, descriptor)
        && appendLogicOperationState(writer, descriptor)
        && provenance.function(Role::Object, descriptor.objectFunction)
        && provenance.function(Role::Mesh, descriptor.meshFunction)
        && provenance.function(Role::Fragment, descriptor.fragmentFunction)
        && provenance.linked(Role::ObjectPrivate, descriptor.objectLinkedFunctions)
        && provenance.linked(Role::MeshPrivate, descriptor.meshLinkedFunctions)
        && provenance.linked(Role::FragmentPrivate, descriptor.fragmentLinkedFunctions);
}

void appendMtl4ColorAttachment(
    Writer& writer,
    MTL4RenderPipelineColorAttachmentDescriptor* attachment) API_AVAILABLE(macos(26.0)) {
    writer.pod(static_cast<std::uint64_t>(attachment.pixelFormat));
    writer.pod(static_cast<std::uint64_t>(attachment.blendingState));
    writer.pod(static_cast<std::uint64_t>(attachment.sourceRGBBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.destinationRGBBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.rgbBlendOperation));
    writer.pod(static_cast<std::uint64_t>(attachment.sourceAlphaBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.destinationAlphaBlendFactor));
    writer.pod(static_cast<std::uint64_t>(attachment.alphaBlendOperation));
    writer.pod(static_cast<std::uint64_t>(attachment.writeMask));
}

bool appendMtl4Function(
    Writer& writer,
    const Role role,
    MTL4FunctionDescriptor* function,
    id canonicalLibrary,
    NSString* canonicalName) API_AVAILABLE(macos(26.0)) {
    writer.pod(role);
    writer.pod(function != nil);
    if (function == nil) {
        return canonicalLibrary == nil && canonicalName == nil;
    }
    if (![function isKindOfClass:[MTL4LibraryFunctionDescriptor class]]) {
        return false;
    }
    auto* libraryFunction = static_cast<MTL4LibraryFunctionDescriptor*>(function);
    NSString* actualName = libraryFunction.name;
    if (libraryFunction.library != canonicalLibrary
        || (actualName != canonicalName && ![actualName isEqualToString:canonicalName])) {
        return false;
    }
    writer.pod(canonicalName != nil);
    if (canonicalName == nil) {
        return canonicalLibrary == nil;
    }
    return writer.identity(canonicalLibrary) && writer.string(canonicalName);
}

bool appendMtl4PrivateFunctions(
    Writer& writer,
    const Role role,
    NSArray<MTL4FunctionDescriptor*>* functions,
    id canonicalLibrary,
    NSString* canonicalName) API_AVAILABLE(macos(26.0)) {
    const NSUInteger functionCount = functions.count;
    if (functionCount > std::numeric_limits<std::uint32_t>::max()) {
        return false;
    }
    const auto count = static_cast<std::uint32_t>(functionCount);
    writer.pod(count);
    if (count == 0) {
        return canonicalLibrary == nil && canonicalName == nil;
    }
    if (count != 1) {
        return false;
    }
    return appendMtl4Function(writer, role, functions[0], canonicalLibrary, canonicalName);
}

bool appendMtl4(
    Writer& writer,
    const void* owner,
    MTL4RenderPipelineDescriptor* descriptor) API_AVAILABLE(macos(26.0)) {
    MTL4StaticLinkingDescriptor* vertexLinking = descriptor.vertexStaticLinkingDescriptor;
    MTL4StaticLinkingDescriptor* fragmentLinking = descriptor.fragmentStaticLinkingDescriptor;
    if (vertexLinking.functionDescriptors.count != 0 || vertexLinking.groups.count != 0
        || fragmentLinking.functionDescriptors.count != 0
        || fragmentLinking.privateFunctionDescriptors.count != 0
        || fragmentLinking.groups.count != 0) {
        return false;
    }

    writer.pod(static_cast<std::uint64_t>(descriptor.rasterSampleCount));
    writer.pod(static_cast<std::uint64_t>(descriptor.alphaToCoverageState));
    writer.pod(static_cast<std::uint64_t>(descriptor.alphaToOneState));
    writer.pod(static_cast<bool>(descriptor.rasterizationEnabled));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxVertexAmplificationCount));
    writer.pod(static_cast<std::uint64_t>(descriptor.inputPrimitiveTopology));
    writer.pod(static_cast<bool>(descriptor.supportVertexBinaryLinking));
    writer.pod(static_cast<bool>(descriptor.supportFragmentBinaryLinking));
    writer.pod(static_cast<std::uint64_t>(descriptor.colorAttachmentMappingState));
    writer.pod(static_cast<std::uint64_t>(descriptor.supportIndirectCommandBuffers));
    writer.pod(static_cast<std::uint64_t>(descriptor.options.shaderValidation));
    writer.pod(static_cast<std::uint64_t>(descriptor.options.shaderReflection));
    for (NSUInteger index = 0; index < 8; ++index) {
        appendMtl4ColorAttachment(writer, descriptor.colorAttachments[index]);
    }

    // LoadFunctions retained these exact canonical library/name pairs. Match
    // the final copied descriptors against them; unlike MTLFunction, the MTL4
    // library descriptor has a documented library property.
    return appendMtl4Function(
               writer,
               Role::Vertex,
               descriptor.vertexFunctionDescriptor,
               load<id>(owner, 0x548),
               load<NSString*>(owner, 0x550))
        && appendMtl4Function(
               writer,
               Role::Fragment,
               descriptor.fragmentFunctionDescriptor,
               load<id>(owner, 0x5a0),
               load<NSString*>(owner, 0x5a8))
        && appendMtl4PrivateFunctions(
               writer,
               Role::VertexPrivate,
               vertexLinking.privateFunctionDescriptors,
               load<id>(owner, 0x570),
               load<NSString*>(owner, 0x568));
}

bool makeGraphicsKey(
    const Api api,
    const void* owner,
    id descriptor,
    Writer& writer) {
    const void* stages = load<const void*>(owner, kGraphicsStagesOffset);
    if (stages == nullptr) {
        return false;
    }
    const GraphicsProvenance provenance {owner, stages, writer};
    if (!provenance.stageTable() || !provenance.functionConstants()) {
        return false;
    }
    bool complete = false;
    switch (api) {
    case Api::Metal4Render:
        if (@available(macOS 26.0, *)) {
            if (![descriptor isKindOfClass:[MTL4RenderPipelineDescriptor class]]) {
                return false;
            }
            complete = appendMtl4(
                writer,
                owner,
                static_cast<MTL4RenderPipelineDescriptor*>(descriptor));
        } else {
            return false;
        }
        break;
    case Api::Render:
        if (![descriptor isKindOfClass:[MTLRenderPipelineDescriptor class]]) {
            return false;
        }
        complete = appendLegacy(writer, provenance, static_cast<MTLRenderPipelineDescriptor*>(descriptor));
        break;
    case Api::Mesh:
        if (![descriptor isKindOfClass:[MTLMeshRenderPipelineDescriptor class]]) {
            return false;
        }
        complete = appendMesh(writer, provenance, static_cast<MTLMeshRenderPipelineDescriptor*>(descriptor));
        break;
    case Api::Compute:
        return false;
    }
    return complete;
}

bool makeComputeKey(const void* owner, MTLComputePipelineDescriptor* descriptor, Writer& writer) {
    const void* stages = load<const void*>(owner, kComputeStagesOffset);
    if (stages == nullptr) {
        return false;
    }
    const void* stage = load<const void*>(stages, 0x38);
    if (stage == nullptr || descriptor.computeFunction == nil) {
        return false;
    }
    id library = load<id>(stage, kStageLibraryOffset);
    writer.pod(Role::Compute);
    if (!writer.identity(library)) {
        return false;
    }
    writer.pod(static_cast<std::uint64_t>(descriptor.computeFunction.functionType));
    if (!writer.string(descriptor.computeFunction.name)) {
        return false;
    }
    writer.pod(static_cast<bool>(descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxTotalThreadsPerThreadgroup));
    writer.pod(static_cast<bool>(descriptor.supportIndirectCommandBuffers));
    writer.pod(static_cast<bool>(descriptor.supportAddingBinaryFunctions));
    writer.pod(static_cast<std::uint64_t>(descriptor.maxCallStackDepth));
    if (@available(macOS 15.0, *)) {
        writer.pod(true);
        writer.pod(static_cast<std::uint64_t>(descriptor.shaderValidation));
    } else {
        writer.pod(false);
        writer.pod(std::uint64_t {0});
    }
    if (@available(macOS 26.0, *)) {
        writer.pod(true);
        writer.pod(descriptor.requiredThreadsPerThreadgroup);
    } else {
        writer.pod(false);
        writer.pod(MTLSize {0, 0, 0});
    }
    return true;
}

} // namespace

bool makeKey(
    const Api api,
    const void* device,
    id descriptor,
    const std::uint64_t options,
    const bool reflectionRequested,
    const Context& context,
    Key& output) {
    output.reset();
    if (device == nullptr || descriptor == nil) {
        return false;
    }

    if (api == Api::Compute && context.kind == ContextKind::None) {
        if (![descriptor isKindOfClass:[MTLComputePipelineDescriptor class]]) {
            return false;
        }
        return makeRayTracingKey(
            device,
            static_cast<MTLComputePipelineDescriptor*>(descriptor),
            options,
            reflectionRequested,
            output);
    }
    if (context.owner == nullptr
        || (api == Api::Compute && context.kind != ContextKind::Compute)
        || (api != Api::Compute && context.kind != ContextKind::Graphics)) {
        return false;
    }

    ResourceArray resources;
    if (resources.get() == nil) {
        return false;
    }
    bool complete = false;
    Writer writer(output.bytes, resources.get());
    writer.pod(kKeyFormatVersion);
    writer.pod(api);
    writer.pod(kNativePipelineDomain);
    writer.pod(options);
    writer.pod(reflectionRequested);
    writer.pod(context.dynamicFlags);
    writer.pod(context.formats);

    // The Render, Mesh, and Compute helpers use the native Metal device at
    // +0x40. Only the Metal4Render helper also uses the compiler at +0x48.
    id metalDevice = load<id>(device, 0x40);
    complete = writer.identity(metalDevice);
    if (api == Api::Metal4Render) {
        id metalCompiler = load<id>(device, 0x48);
        complete = writer.identity(metalCompiler) && complete;
    }

    if (complete && api == Api::Compute) {
        if (![descriptor isKindOfClass:[MTLComputePipelineDescriptor class]]) {
            complete = false;
        } else {
            complete = makeComputeKey(
                context.owner,
                static_cast<MTLComputePipelineDescriptor*>(descriptor),
                writer);
        }
    } else if (complete) {
        complete = makeGraphicsKey(api, context.owner, descriptor, writer);
    }
    if (complete) {
        output.resources = resources.take();
        complete = output.resources != nil;
    }
    if (!complete) {
        output.reset();
    }
    return complete;
}

} // namespace yaagl::pso
