#pragma once

#import <Metal/Metal.h>

#include <cstdint>

#include "key.hpp"

namespace yaagl::pso {

enum class RtOriginalSlot : std::uint32_t {
    CreateFunction,
    CreateCombinedAnyHitIntersectionFunction,
    CreateIntersectionWrapperFunction,
    GetAndRetainLibrary,
    Count,
};

using RtCreateFunctionEntry = void* (*)(
    void*, void*, void*, void*, bool, bool);
using RtCreateCombinedEntry = void* (*)(
    void*, void*, void*, void*, void*, bool, bool, bool);
using RtCreateIntersectionEntry = id (*)(void*, bool, bool);
using RtGetAndRetainLibraryEntry = id (*)(void*, id);

struct RtHookEntryPoints final {
    RtCreateFunctionEntry createFunction;
    RtCreateCombinedEntry createCombinedAnyHitIntersectionFunction;
    RtCreateIntersectionEntry createIntersectionWrapperFunction;
    RtGetAndRetainLibraryEntry getAndRetainLibrary;
};

// originalTrampolines contains absolute callable addresses in RtOriginalSlot
// order. imageBase is recorded to reject accidental reinitialization for a
// different D3DMetal image. Call this before publishing the returned entry
// points to the patched gates.
[[nodiscard]] RtHookEntryPoints initializeRtHooks(
    const void* imageBase,
    const void* const originalTrampolines[
        static_cast<std::uint32_t>(RtOriginalSlot::Count)]) noexcept;

// Returns false unless every function which participates in the native RT
// descriptor has canonical provenance captured by the RT creation hooks.
[[nodiscard]] bool makeRayTracingKey(
    const void* device,
    MTLComputePipelineDescriptor* descriptor,
    std::uint64_t options,
    bool reflectionRequested,
    Key& output);

} // namespace yaagl::pso

extern "C" {

void* yaaglPsoRtCreateFunctionHook(
    void* result,
    void* stateObject,
    void* exportSharedPtr,
    void* associations,
    bool extractReflection,
    bool compileFlag);

void* yaaglPsoRtCreateCombinedFunctionHook(
    void* result,
    void* stateObject,
    void* anyHitExportSharedPtr,
    void* intersectionExportSharedPtr,
    void* associations,
    bool extractReflection,
    bool compileFlag,
    bool combinedFlag);

id yaaglPsoRtCreateIntersectionWrapperHook(
    void* stateObject,
    bool extractReflection,
    bool wrapperKind);

id yaaglPsoRtGetAndRetainLibraryHook(void* stageResult, id metalDevice);

}
