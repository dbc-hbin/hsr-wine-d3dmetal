#pragma once

#import <Metal/Metal.h>

#include <cstdint>

namespace yaagl::pso {

enum class StageOriginalSlot : std::uint32_t {
    CompileComputeStages,
    CompileGraphicsStages,
    CreateComputeStageKey,
    CreateGraphicsStageKey,
    Count,
};

using StageCompileEntry = void* (*)(void* cache, void* descriptor);
using StageCreateComputeKeyEntry = void* (*)(void* descriptor);
// The optimized native caller leaves the ignored second source-level argument
// as the descriptor value in RSI. Preserve that raw register instead of
// crossing the hook ABI with a non-canonical C++ bool. The used flag arrives
// zero-extended in EDX.
using StageCreateGraphicsKeyEntry = void* (*)(
    void* descriptor, std::uintptr_t ignoredFlag, std::uint32_t deviceFlag);
using StageGetAndRetainLibraryEntry = id (*)(void* stageResult, id metalDevice);

struct StageHookEntryPoints final {
    StageCompileEntry compileComputeStages;
    StageCompileEntry compileGraphicsStages;
    StageCreateComputeKeyEntry createComputeStageKey;
    StageCreateGraphicsKeyEntry createGraphicsStageKey;
};

// originalTrampolines contains absolute callable addresses in StageOriginalSlot
// order. imageBase rejects accidental initialization for another D3DMetal image.
[[nodiscard]] StageHookEntryPoints initializeStageHooks(
    const void* imageBase,
    const void* const originalTrampolines[
        static_cast<std::uint32_t>(StageOriginalSlot::Count)]) noexcept;

// Coalesces the nil-to-library transition at D3DMStageResult + 0x178. The
// returned object has exactly the ownership supplied by GetAndRetainLibrary.
[[nodiscard]] id getAndRetainLibrarySingleFlight(
    void* stageResult,
    id metalDevice,
    StageGetAndRetainLibraryEntry original);

} // namespace yaagl::pso

extern "C" {

void* yaaglPsoCompileComputeStagesHook(void* cache, void* descriptor);
void* yaaglPsoCompileGraphicsStagesHook(void* cache, void* descriptor);
void* yaaglPsoCreateComputeStageKeyHook(void* descriptor);
void* yaaglPsoCreateGraphicsStageKeyHook(
    void* descriptor,
    std::uintptr_t ignoredFlag,
    std::uint32_t deviceFlag);

}
