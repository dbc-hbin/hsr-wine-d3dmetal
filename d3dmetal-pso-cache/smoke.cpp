#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>
#include <d3dcompiler.h>
#include <wrl/client.h>

#include <array>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>

#ifdef YAAGL_SMOKE_RT_DXIL_HEADER
#include YAAGL_SMOKE_RT_DXIL_HEADER
#endif

using Microsoft::WRL::ComPtr;

namespace {

[[noreturn]] void fail(const char* what, HRESULT hr = E_FAIL) {
    std::fprintf(stderr, "d3dmetal-pso-cache-smoke: %s (HRESULT=0x%08lx)\n",
                 what, static_cast<unsigned long>(hr));
    std::exit(1);
}

void check(HRESULT hr, const char* what) {
    if (FAILED(hr)) fail(what, hr);
}

void phase(const char* name) {
    std::fprintf(stderr, "PSO_SMOKE_PHASE %s\n", name);
    std::fflush(stderr);
}

ComPtr<ID3DBlob> compile(const char* source, const char* entry, const char* target) {
    std::fprintf(stderr, "PSO_SMOKE_PHASE hlsl-%s-begin\n", target);
    std::fflush(stderr);
    ComPtr<ID3DBlob> code;
    ComPtr<ID3DBlob> errors;
    const HRESULT hr = D3DCompile(source, std::strlen(source), "smoke.hlsl", nullptr,
                                  nullptr, entry, target,
                                  D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3,
                                  0, &code, &errors);
    if (FAILED(hr)) {
        if (errors) std::fwrite(errors->GetBufferPointer(), 1, errors->GetBufferSize(), stderr);
        fail("D3DCompile", hr);
    }
    std::fprintf(stderr, "PSO_SMOKE_PHASE hlsl-%s-end\n", target);
    std::fflush(stderr);
    return code;
}

ComPtr<ID3D12RootSignature> rootSignature(ID3D12Device* device,
                                          const D3D12_ROOT_SIGNATURE_DESC& desc) {
    ComPtr<ID3DBlob> blob;
    ComPtr<ID3DBlob> errors;
    const HRESULT hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1,
                                                    &blob, &errors);
    if (FAILED(hr)) {
        if (errors) std::fwrite(errors->GetBufferPointer(), 1, errors->GetBufferSize(), stderr);
        fail("D3D12SerializeRootSignature", hr);
    }
    ComPtr<ID3D12RootSignature> result;
    check(device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                      IID_PPV_ARGS(&result)),
          "CreateRootSignature");
    return result;
}

D3D12_HEAP_PROPERTIES heapProperties(D3D12_HEAP_TYPE type) {
    D3D12_HEAP_PROPERTIES value{};
    value.Type = type;
    value.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
    value.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
    value.CreationNodeMask = 1;
    value.VisibleNodeMask = 1;
    return value;
}

D3D12_RESOURCE_DESC bufferDesc(UINT64 size, D3D12_RESOURCE_FLAGS flags) {
    D3D12_RESOURCE_DESC value{};
    value.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    value.Width = size;
    value.Height = 1;
    value.DepthOrArraySize = 1;
    value.MipLevels = 1;
    value.Format = DXGI_FORMAT_UNKNOWN;
    value.SampleDesc.Count = 1;
    value.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    value.Flags = flags;
    return value;
}

ComPtr<ID3D12Resource> buffer(ID3D12Device* device, UINT64 size,
                              D3D12_HEAP_TYPE heap, D3D12_RESOURCE_FLAGS flags,
                              D3D12_RESOURCE_STATES state) {
    const auto properties = heapProperties(heap);
    const auto desc = bufferDesc(size, flags);
    ComPtr<ID3D12Resource> result;
    check(device->CreateCommittedResource(&properties, D3D12_HEAP_FLAG_NONE, &desc,
                                           state, nullptr, IID_PPV_ARGS(&result)),
          "CreateCommittedResource(buffer)");
    return result;
}

void transition(ID3D12GraphicsCommandList* list, ID3D12Resource* resource,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    list->ResourceBarrier(1, &barrier);
}

class Gpu final {
public:
    explicit Gpu(ID3D12Device* sharedDevice = nullptr) {
        if (sharedDevice) {
            device = sharedDevice;
        } else {
            phase("device-create-begin");
            check(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)),
                  "D3D12CreateDevice");
            phase("device-create-end");
        }
        D3D12_COMMAND_QUEUE_DESC queueDesc{};
        queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        check(device->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(&queue)),
              "CreateCommandQueue");
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                              IID_PPV_ARGS(&allocator)),
              "CreateCommandAllocator");
        check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(),
                                        nullptr, IID_PPV_ARGS(&list)),
              "CreateCommandList");
        check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)),
              "CreateFence");
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event) fail("CreateEventW", HRESULT_FROM_WIN32(GetLastError()));
    }

    ~Gpu() { CloseHandle(event); }

    void submit() {
        phase("gpu-submit-begin");
        check(list->Close(), "Close command list");
        ID3D12CommandList* lists[] = {list.Get()};
        queue->ExecuteCommandLists(1, lists);
        check(queue->Signal(fence.Get(), 1), "Signal fence");
        check(fence->SetEventOnCompletion(1, event), "SetEventOnCompletion");
        phase("gpu-fence-wait-begin");
        if (WaitForSingleObject(event, INFINITE) != WAIT_OBJECT_0) fail("fence wait");
        phase("gpu-fence-wait-end");
        check(device->GetDeviceRemovedReason(), "GPU execution/device removal");
        phase("gpu-submit-end");
    }

    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> list;

private:
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
};

class StartGate final {
public:
    void wait() {
        std::unique_lock<std::mutex> lock(mutex);
        if (++arrived == 2) condition.notify_all();
        condition.wait(lock, [this] { return arrived == 2; });
    }

private:
    int arrived = 0;
    std::mutex mutex;
    std::condition_variable condition;
};

template<typename Desc>
std::array<ComPtr<ID3D12PipelineState>, 2> concurrentCreate(
    ID3D12Device* device, const Desc& desc, bool graphics) {
    std::array<ComPtr<ID3D12PipelineState>, 2> result;
    std::array<HRESULT, 2> status{E_FAIL, E_FAIL};
    StartGate gate;
    std::thread first([&] {
        gate.wait();
        std::fprintf(stderr, "PSO_SMOKE_PHASE %s-worker-0-create-begin\n",
                     graphics ? "graphics" : "compute");
        std::fflush(stderr);
        status[0] = graphics
            ? device->CreateGraphicsPipelineState(
                  reinterpret_cast<const D3D12_GRAPHICS_PIPELINE_STATE_DESC*>(&desc),
                  IID_PPV_ARGS(&result[0]))
            : device->CreateComputePipelineState(
                  reinterpret_cast<const D3D12_COMPUTE_PIPELINE_STATE_DESC*>(&desc),
                  IID_PPV_ARGS(&result[0]));
        std::fprintf(stderr, "PSO_SMOKE_PHASE %s-worker-0-create-end hr=0x%08lx\n",
                     graphics ? "graphics" : "compute",
                     static_cast<unsigned long>(status[0]));
        std::fflush(stderr);
    });
    gate.wait();
    std::fprintf(stderr, "PSO_SMOKE_PHASE %s-worker-1-create-begin\n",
                 graphics ? "graphics" : "compute");
    std::fflush(stderr);
    status[1] = graphics
        ? device->CreateGraphicsPipelineState(
              reinterpret_cast<const D3D12_GRAPHICS_PIPELINE_STATE_DESC*>(&desc),
              IID_PPV_ARGS(&result[1]))
        : device->CreateComputePipelineState(
              reinterpret_cast<const D3D12_COMPUTE_PIPELINE_STATE_DESC*>(&desc),
              IID_PPV_ARGS(&result[1]));
    std::fprintf(stderr, "PSO_SMOKE_PHASE %s-worker-1-create-end hr=0x%08lx\n",
                 graphics ? "graphics" : "compute",
                 static_cast<unsigned long>(status[1]));
    std::fflush(stderr);
    first.join();
    check(status[0], graphics ? "concurrent graphics PSO #1" : "concurrent compute PSO #1");
    check(status[1], graphics ? "concurrent graphics PSO #2" : "concurrent compute PSO #2");
    ComPtr<IUnknown> firstIdentity;
    ComPtr<IUnknown> secondIdentity;
    check(result[0].As(&firstIdentity), "QueryInterface(concurrent PSO #1 identity)");
    check(result[1].As(&secondIdentity), "QueryInterface(concurrent PSO #2 identity)");
    if (firstIdentity.Get() == secondIdentity.Get()) {
        fail("D3D12 PSO identity was incorrectly shared");
    }
    return result;
}

D3D12_BLEND_DESC blend(bool enabled) {
    D3D12_BLEND_DESC value{};
    value.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    if (enabled) {
        auto& target = value.RenderTarget[0];
        target.BlendEnable = TRUE;
        target.SrcBlend = D3D12_BLEND_SRC_ALPHA;
        target.DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
        target.BlendOp = D3D12_BLEND_OP_ADD;
        target.SrcBlendAlpha = D3D12_BLEND_ONE;
        target.DestBlendAlpha = D3D12_BLEND_ZERO;
        target.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    }
    return value;
}

D3D12_RASTERIZER_DESC rasterizer() {
    D3D12_RASTERIZER_DESC value{};
    value.FillMode = D3D12_FILL_MODE_SOLID;
    value.CullMode = D3D12_CULL_MODE_NONE;
    value.DepthClipEnable = TRUE;
    return value;
}

bool allDistinct(const std::array<ComPtr<ID3D12PipelineState>, 4>& pipelines) {
    std::array<ComPtr<IUnknown>, 4> identities;
    for (std::size_t index = 0; index < pipelines.size(); ++index) {
        check(pipelines[index].As(&identities[index]), "QueryInterface(logic-op PSO identity)");
        for (std::size_t prior = 0; prior < index; ++prior) {
            if (identities[index].Get() == identities[prior].Get()) return false;
        }
    }
    return true;
}

std::array<std::uint8_t, 4> runRender(
    Gpu& gpu, ID3D12PipelineState* pipeline, ID3D12RootSignature* root, bool indirect,
    DXGI_FORMAT format = DXGI_FORMAT_R8G8B8A8_UNORM, UINT sampleCount = 1) {
    D3D12_RESOURCE_DESC texture{};
    texture.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    texture.Width = 4;
    texture.Height = 4;
    texture.DepthOrArraySize = 1;
    texture.MipLevels = 1;
    texture.Format = format;
    texture.SampleDesc.Count = sampleCount;
    texture.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    texture.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    const auto defaultHeap = heapProperties(D3D12_HEAP_TYPE_DEFAULT);
    D3D12_CLEAR_VALUE clear{};
    clear.Format = texture.Format;
    ComPtr<ID3D12Resource> target;
    check(gpu.device->CreateCommittedResource(&defaultHeap, D3D12_HEAP_FLAG_NONE, &texture,
                                               D3D12_RESOURCE_STATE_RENDER_TARGET, &clear,
                                               IID_PPV_ARGS(&target)),
          "CreateCommittedResource(render target)");

    D3D12_DESCRIPTOR_HEAP_DESC heapDesc{};
    heapDesc.NumDescriptors = 1;
    heapDesc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    ComPtr<ID3D12DescriptorHeap> rtvHeap;
    check(gpu.device->CreateDescriptorHeap(&heapDesc, IID_PPV_ARGS(&rtvHeap)),
          "CreateDescriptorHeap(RTV)");
    const auto rtv = rtvHeap->GetCPUDescriptorHandleForHeapStart();
    gpu.device->CreateRenderTargetView(target.Get(), nullptr, rtv);

    D3D12_RESOURCE_DESC readbackTexture = texture;
    readbackTexture.SampleDesc.Count = 1;
    readbackTexture.Flags = D3D12_RESOURCE_FLAG_NONE;
    ComPtr<ID3D12Resource> resolvedTarget;
    if (sampleCount > 1) {
        check(gpu.device->CreateCommittedResource(
                  &defaultHeap, D3D12_HEAP_FLAG_NONE, &readbackTexture,
                  D3D12_RESOURCE_STATE_RESOLVE_DEST, nullptr, IID_PPV_ARGS(&resolvedTarget)),
              "CreateCommittedResource(resolve target)");
    }
    UINT64 readbackSize = 0;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    gpu.device->GetCopyableFootprints(&readbackTexture, 0, 1, 0, &footprint, nullptr, nullptr,
                                      &readbackSize);
    auto readback = buffer(gpu.device.Get(), readbackSize, D3D12_HEAP_TYPE_READBACK,
                           D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);

    gpu.list->SetPipelineState(pipeline);
    gpu.list->SetGraphicsRootSignature(root);
    gpu.list->OMSetRenderTargets(1, &rtv, FALSE, nullptr);
    const float black[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    gpu.list->ClearRenderTargetView(rtv, black, 0, nullptr);
    const D3D12_VIEWPORT viewport{0, 0, 4, 4, 0, 1};
    const D3D12_RECT rect{0, 0, 4, 4};
    gpu.list->RSSetViewports(1, &viewport);
    gpu.list->RSSetScissorRects(1, &rect);
    gpu.list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ComPtr<ID3D12CommandSignature> indirectSignature;
    ComPtr<ID3D12Resource> indirectArguments;
    if (indirect) {
        D3D12_INDIRECT_ARGUMENT_DESC argument{};
        argument.Type = D3D12_INDIRECT_ARGUMENT_TYPE_DRAW;
        D3D12_COMMAND_SIGNATURE_DESC signatureDesc{};
        signatureDesc.ByteStride = sizeof(D3D12_DRAW_ARGUMENTS);
        signatureDesc.NumArgumentDescs = 1;
        signatureDesc.pArgumentDescs = &argument;
        check(gpu.device->CreateCommandSignature(&signatureDesc, nullptr,
                                                  IID_PPV_ARGS(&indirectSignature)),
              "CreateCommandSignature");
        indirectArguments = buffer(gpu.device.Get(), sizeof(D3D12_DRAW_ARGUMENTS),
                                   D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_FLAG_NONE,
                                   D3D12_RESOURCE_STATE_GENERIC_READ);
        void* mapped = nullptr;
        check(indirectArguments->Map(0, nullptr, &mapped), "Map indirect arguments");
        const D3D12_DRAW_ARGUMENTS draw{3, 1, 0, 0};
        std::memcpy(mapped, &draw, sizeof(draw));
        indirectArguments->Unmap(0, nullptr);
        gpu.list->ExecuteIndirect(indirectSignature.Get(), 1, indirectArguments.Get(), 0,
                                  nullptr, 0);
    } else {
        gpu.list->DrawInstanced(3, 1, 0, 0);
    }
    ID3D12Resource* copySource = target.Get();
    if (sampleCount > 1) {
        transition(gpu.list.Get(), target.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET,
                   D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
        gpu.list->ResolveSubresource(resolvedTarget.Get(), 0, target.Get(), 0, format);
        transition(gpu.list.Get(), resolvedTarget.Get(), D3D12_RESOURCE_STATE_RESOLVE_DEST,
                   D3D12_RESOURCE_STATE_COPY_SOURCE);
        copySource = resolvedTarget.Get();
    } else {
        transition(gpu.list.Get(), target.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET,
                   D3D12_RESOURCE_STATE_COPY_SOURCE);
    }
    D3D12_TEXTURE_COPY_LOCATION source{};
    source.pResource = copySource;
    source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION destination{};
    destination.pResource = readback.Get();
    destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    destination.PlacedFootprint = footprint;
    gpu.list->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
    gpu.submit();

    void* mappedRaw = nullptr;
    D3D12_RANGE range{0, static_cast<SIZE_T>(readbackSize)};
    check(readback->Map(0, &range, &mappedRaw), "Map render readback");
    const auto* mapped = static_cast<const std::uint8_t*>(mappedRaw);
    std::array<std::uint8_t, 4> pixel{mapped[0], mapped[1], mapped[2], mapped[3]};
    readback->Unmap(0, nullptr);
    return pixel;
}

std::uint32_t runCompute(Gpu& gpu, ID3D12PipelineState* pipeline,
                         ID3D12RootSignature* root) {
    auto output = buffer(gpu.device.Get(), 4, D3D12_HEAP_TYPE_DEFAULT,
                         D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
                         D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    auto readback = buffer(gpu.device.Get(), 4, D3D12_HEAP_TYPE_READBACK,
                           D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    gpu.list->SetPipelineState(pipeline);
    gpu.list->SetComputeRootSignature(root);
    gpu.list->SetComputeRootUnorderedAccessView(0, output->GetGPUVirtualAddress());
    gpu.list->Dispatch(1, 1, 1);
    transition(gpu.list.Get(), output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
               D3D12_RESOURCE_STATE_COPY_SOURCE);
    gpu.list->CopyBufferRegion(readback.Get(), 0, output.Get(), 0, 4);
    gpu.submit();
    void* mappedRaw = nullptr;
    const D3D12_RANGE range{0, 4};
    check(readback->Map(0, &range, &mappedRaw), "Map compute readback");
    const std::uint32_t result = *static_cast<const std::uint32_t*>(mappedRaw);
    readback->Unmap(0, nullptr);
    return result;
}

#ifdef YAAGL_SMOKE_RT_DXIL_HEADER
std::uint32_t runRayTracing(Gpu& gpu, ID3D12RootSignature* root,
                            ID3D12StateObject* stateObject) {
    ComPtr<ID3D12StateObjectProperties> properties;
    check(stateObject->QueryInterface(IID_PPV_ARGS(&properties)),
          "ID3D12StateObjectProperties");
    const void* identifier = properties->GetShaderIdentifier(L"RayGen");
    if (!identifier) fail("RayGen shader identifier");
    auto shaderTable = buffer(gpu.device.Get(), D3D12_RAYTRACING_SHADER_TABLE_BYTE_ALIGNMENT,
                              D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_FLAG_NONE,
                              D3D12_RESOURCE_STATE_GENERIC_READ);
    void* shaderTableBytes = nullptr;
    check(shaderTable->Map(0, nullptr, &shaderTableBytes), "Map raygen shader table");
    std::memset(shaderTableBytes, 0, D3D12_RAYTRACING_SHADER_TABLE_BYTE_ALIGNMENT);
    std::memcpy(shaderTableBytes, identifier, D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES);
    shaderTable->Unmap(0, nullptr);

    auto output = buffer(gpu.device.Get(), 4, D3D12_HEAP_TYPE_DEFAULT,
                         D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
                         D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    auto readback = buffer(gpu.device.Get(), 4, D3D12_HEAP_TYPE_READBACK,
                           D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    ComPtr<ID3D12GraphicsCommandList4> list4;
    check(gpu.list.As(&list4), "ID3D12GraphicsCommandList4");
    list4->SetComputeRootSignature(root);
    list4->SetComputeRootUnorderedAccessView(0, output->GetGPUVirtualAddress());
    list4->SetPipelineState1(stateObject);
    D3D12_DISPATCH_RAYS_DESC dispatch{};
    dispatch.RayGenerationShaderRecord.StartAddress = shaderTable->GetGPUVirtualAddress();
    dispatch.RayGenerationShaderRecord.SizeInBytes = D3D12_SHADER_IDENTIFIER_SIZE_IN_BYTES;
    dispatch.Width = 1;
    dispatch.Height = 1;
    dispatch.Depth = 1;
    list4->DispatchRays(&dispatch);
    transition(gpu.list.Get(), output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
               D3D12_RESOURCE_STATE_COPY_SOURCE);
    gpu.list->CopyBufferRegion(readback.Get(), 0, output.Get(), 0, 4);
    gpu.submit();
    void* mappedRaw = nullptr;
    const D3D12_RANGE range{0, 4};
    check(readback->Map(0, &range, &mappedRaw), "Map ray tracing readback");
    const auto value = *static_cast<const std::uint32_t*>(mappedRaw);
    readback->Unmap(0, nullptr);
    return value;
}

std::array<ComPtr<ID3D12StateObject>, 2> concurrentCreateRt(
    ID3D12Device5* device, const D3D12_STATE_OBJECT_DESC& desc) {
    std::array<ComPtr<ID3D12StateObject>, 2> result;
    std::array<HRESULT, 2> status{E_FAIL, E_FAIL};
    StartGate gate;
    std::thread first([&] {
        gate.wait();
        phase("rt-worker-0-create-begin");
        status[0] = device->CreateStateObject(&desc, IID_PPV_ARGS(&result[0]));
        phase("rt-worker-0-create-end");
    });
    gate.wait();
    phase("rt-worker-1-create-begin");
    status[1] = device->CreateStateObject(&desc, IID_PPV_ARGS(&result[1]));
    phase("rt-worker-1-create-end");
    first.join();
    check(status[0], "concurrent RT state object #1");
    check(status[1], "concurrent RT state object #2");
    ComPtr<IUnknown> firstIdentity;
    ComPtr<IUnknown> secondIdentity;
    check(result[0].As(&firstIdentity), "QueryInterface(concurrent RT #1 identity)");
    check(result[1].As(&secondIdentity), "QueryInterface(concurrent RT #2 identity)");
    if (firstIdentity.Get() == secondIdentity.Get()) {
        fail("D3D12 RT object identity was shared");
    }
    return result;
}
#endif

void requirePixel(const std::array<std::uint8_t, 4>& actual,
                  const std::array<std::uint8_t, 4>& expected, const char* label) {
    if (actual != expected) {
        std::fprintf(stderr, "%s: got [%u,%u,%u,%u], expected [%u,%u,%u,%u]\n", label,
                     actual[0], actual[1], actual[2], actual[3], expected[0], expected[1],
                     expected[2], expected[3]);
        std::exit(1);
    }
}

void requireHalfGreenPixel(const std::array<std::uint8_t, 4>& actual,
                           bool blended, const char* label) {
    const auto half = [](std::uint8_t value) { return value == 127 || value == 128; };
    const bool valid = actual[0] == 0 && actual[2] == 0 && half(actual[3]) &&
                       (blended ? half(actual[1]) : actual[1] == 255);
    if (!valid) {
        std::fprintf(stderr,
                     "%s: got [%u,%u,%u,%u], expected [0,%s,0,127-or-128]\n",
                     label, actual[0], actual[1], actual[2], actual[3],
                     blended ? "127-or-128" : "255");
        std::exit(1);
    }
}

} // namespace

int main() {
    static constexpr char vertexShader[] =
        "float4 main(uint id:SV_VertexID):SV_Position {"
        "float2 p[3]={float2(-1,-1),float2(-1,3),float2(3,-1)};"
        "return float4(p[id],0,1);}";
    static constexpr char redShader[] =
        "float4 main():SV_Target { return float4(1,0,0,1); }";
    static constexpr char halfGreenShader[] =
        "float4 main():SV_Target { return float4(0,1,0,0.5); }";
    static constexpr char opaqueGreenShader[] =
        "float4 main():SV_Target { return float4(0,1,0,1); }";
    static constexpr char computeA[] =
        "RWByteAddressBuffer outBuffer:register(u0);"
        "[numthreads(1,1,1)] void main(){outBuffer.Store(0,0x13579bdf);}";
    static constexpr char computeB[] =
        "RWByteAddressBuffer outBuffer:register(u0);"
        "[numthreads(1,1,1)] void main(){outBuffer.Store(0,0x2468ace0);}";

    Gpu gpu;
    D3D12_FEATURE_DATA_D3D12_OPTIONS options{};
    check(gpu.device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS, &options,
                                           sizeof(options)),
          "D3D12_OPTIONS");
    if (!options.OutputMergerLogicOp) {
        fail("candidate reports no D3D12 output-merger logic-op support");
    }
    D3D12_ROOT_SIGNATURE_DESC emptyDesc{};
    emptyDesc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    auto graphicsRoot = rootSignature(gpu.device.Get(), emptyDesc);
    const auto vs = compile(vertexShader, "main", "vs_5_0");
    const auto red = compile(redShader, "main", "ps_5_0");
    const auto green = compile(halfGreenShader, "main", "ps_5_0");
    const auto opaqueGreen = compile(opaqueGreenShader, "main", "ps_5_0");

    D3D12_GRAPHICS_PIPELINE_STATE_DESC graphics{};
    graphics.pRootSignature = graphicsRoot.Get();
    graphics.VS = {vs->GetBufferPointer(), vs->GetBufferSize()};
    graphics.PS = {red->GetBufferPointer(), red->GetBufferSize()};
    graphics.BlendState = blend(false);
    graphics.SampleMask = UINT_MAX;
    graphics.RasterizerState = rasterizer();
    graphics.DepthStencilState.DepthEnable = FALSE;
    graphics.DepthStencilState.StencilEnable = FALSE;
    graphics.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    graphics.NumRenderTargets = 1;
    graphics.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    graphics.SampleDesc.Count = 1;
    phase("concurrent-graphics-begin");
    auto duplicateGraphics = concurrentCreate(gpu.device.Get(), graphics, true);
    phase("concurrent-graphics-end");

    D3D12_GRAPHICS_PIPELINE_STATE_DESC greenUnblendedGraphics = graphics;
    greenUnblendedGraphics.PS = {green->GetBufferPointer(), green->GetBufferSize()};
    ComPtr<ID3D12PipelineState> greenUnblendedRender;
    check(gpu.device->CreateGraphicsPipelineState(&greenUnblendedGraphics,
                                                   IID_PPV_ARGS(&greenUnblendedRender)),
          "different shader graphics PSO");
    D3D12_GRAPHICS_PIPELINE_STATE_DESC greenBlendedGraphics = greenUnblendedGraphics;
    greenBlendedGraphics.BlendState = blend(true);
    ComPtr<ID3D12PipelineState> greenBlendedRender;
    check(gpu.device->CreateGraphicsPipelineState(&greenBlendedGraphics,
                                                   IID_PPV_ARGS(&greenBlendedRender)),
          "different blend graphics PSO");

    D3D12_GRAPHICS_PIPELINE_STATE_DESC logicBaseline = graphics;
    logicBaseline.PS = {opaqueGreen->GetBufferPointer(), opaqueGreen->GetBufferSize()};
    logicBaseline.BlendState = blend(false);
    auto& logicTarget = logicBaseline.BlendState.RenderTarget[0];
    logicTarget.SrcBlend = D3D12_BLEND_ONE;
    logicTarget.DestBlend = D3D12_BLEND_ZERO;
    logicTarget.BlendOp = D3D12_BLEND_OP_ADD;
    logicTarget.SrcBlendAlpha = D3D12_BLEND_ONE;
    logicTarget.DestBlendAlpha = D3D12_BLEND_ZERO;
    logicTarget.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    logicTarget.LogicOp = D3D12_LOGIC_OP_COPY;
    std::array<D3D12_GRAPHICS_PIPELINE_STATE_DESC, 4> logicDescriptions{
        logicBaseline, logicBaseline, logicBaseline, logicBaseline};
    logicDescriptions[1].BlendState.RenderTarget[0].LogicOpEnable = TRUE;
    logicDescriptions[1].BlendState.RenderTarget[0].LogicOp = D3D12_LOGIC_OP_COPY;
    logicDescriptions[2].BlendState.RenderTarget[0].LogicOpEnable = TRUE;
    logicDescriptions[2].BlendState.RenderTarget[0].LogicOp = D3D12_LOGIC_OP_INVERT;
    logicDescriptions[3].BlendState.RenderTarget[0].LogicOpEnable = TRUE;
    logicDescriptions[3].BlendState.RenderTarget[0].LogicOp = D3D12_LOGIC_OP_NOOP;
    std::array<ComPtr<ID3D12PipelineState>, 4> logicPipelines;
    static constexpr const char* logicCreateLabels[] = {
        "logic-op disabled baseline PSO", "logic-op COPY PSO", "logic-op INVERT PSO",
        "logic-op NOOP PSO"};
    for (std::size_t index = 0; index < logicPipelines.size(); ++index) {
        check(gpu.device->CreateGraphicsPipelineState(&logicDescriptions[index],
                                                       IID_PPV_ARGS(&logicPipelines[index])),
              logicCreateLabels[index]);
    }
    if (!allDistinct(logicPipelines)) {
        fail("logic-op PSOs did not have four distinct COM identities");
    }

    Gpu logicBaselineGpu(gpu.device.Get());
    const auto logicBaselinePixel = runRender(
        logicBaselineGpu, logicPipelines[0].Get(), graphicsRoot.Get(), false);
    Gpu logicCopyGpu(gpu.device.Get());
    const auto logicCopyPixel = runRender(
        logicCopyGpu, logicPipelines[1].Get(), graphicsRoot.Get(), false);
    Gpu logicInvertGpu(gpu.device.Get());
    const auto logicInvertPixel = runRender(
        logicInvertGpu, logicPipelines[2].Get(), graphicsRoot.Get(), false);
    Gpu logicNoopGpu(gpu.device.Get());
    const auto logicNoopPixel = runRender(
        logicNoopGpu, logicPipelines[3].Get(), graphicsRoot.Get(), false);
    requirePixel(logicBaselinePixel, {0, 255, 0, 255}, "logic-op disabled baseline readback");
    requirePixel(logicCopyPixel, {0, 255, 0, 255}, "logic-op COPY readback");
    requirePixel(logicInvertPixel, {255, 255, 255, 255}, "logic-op INVERT readback");
    requirePixel(logicNoopPixel, {0, 0, 0, 0}, "logic-op NOOP readback");

    phase("render-direct-0-begin");
    const auto directPixel0 = runRender(gpu, duplicateGraphics[0].Get(), graphicsRoot.Get(), false);
    requirePixel(directPixel0, {255, 0, 0, 255}, "direct render #0 readback");
    phase("render-direct-0-end");
    Gpu directGpu1(gpu.device.Get());
    phase("render-direct-1-begin");
    const auto directPixel1 = runRender(directGpu1, duplicateGraphics[1].Get(),
                                        graphicsRoot.Get(), false);
    requirePixel(directPixel1, {255, 0, 0, 255}, "direct render #1 readback");
    phase("render-direct-1-end");

    Gpu indirectGpu0(gpu.device.Get());
    phase("render-indirect-0-begin");
    const auto indirectPixel0 = runRender(indirectGpu0, duplicateGraphics[0].Get(),
                                          graphicsRoot.Get(), true);
    requirePixel(indirectPixel0, {255, 0, 0, 255}, "ExecuteIndirect render #0 readback");
    phase("render-indirect-0-end");
    Gpu indirectGpu1(gpu.device.Get());
    phase("render-indirect-1-begin");
    const auto indirectPixel1 = runRender(indirectGpu1, duplicateGraphics[1].Get(),
                                          graphicsRoot.Get(), true);
    requirePixel(indirectPixel1, {255, 0, 0, 255}, "ExecuteIndirect render #1 readback");
    phase("render-indirect-1-end");
    Gpu greenUnblendedGpu(gpu.device.Get());
    phase("render-green-unblended-begin");
    const auto greenUnblendedPixel = runRender(greenUnblendedGpu, greenUnblendedRender.Get(),
                                               graphicsRoot.Get(), false);
    requireHalfGreenPixel(greenUnblendedPixel, false, "different shader readback");
    phase("render-green-unblended-end");
    Gpu greenBlendedGpu(gpu.device.Get());
    phase("render-green-blended-begin");
    const auto greenBlendedPixel = runRender(greenBlendedGpu, greenBlendedRender.Get(),
                                             graphicsRoot.Get(), false);
    requireHalfGreenPixel(greenBlendedPixel, true, "different blend readback");
    phase("render-green-blended-end");

    // Format and sample-count controls must produce different cache keys and valid output
    // with resources matching each pipeline description.
    D3D12_GRAPHICS_PIPELINE_STATE_DESC bgraGraphics = graphics;
    bgraGraphics.RTVFormats[0] = DXGI_FORMAT_B8G8R8A8_UNORM;
    ComPtr<ID3D12PipelineState> bgraPso;
    check(gpu.device->CreateGraphicsPipelineState(&bgraGraphics, IID_PPV_ARGS(&bgraPso)),
          "different render-target format PSO");
    Gpu bgraGpu(gpu.device.Get());
    const auto bgraPixel = runRender(bgraGpu, bgraPso.Get(), graphicsRoot.Get(), false,
                                     DXGI_FORMAT_B8G8R8A8_UNORM);
    requirePixel(bgraPixel, {0, 0, 255, 255}, "different render-target format readback");
    D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS msaa{};
    msaa.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    msaa.SampleCount = 4;
    check(gpu.device->CheckFeatureSupport(D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS,
                                           &msaa, sizeof(msaa)),
          "D3D12 multisample quality levels");
    const bool msaa4xSupported = msaa.NumQualityLevels != 0;
    if (msaa4xSupported) {
        D3D12_GRAPHICS_PIPELINE_STATE_DESC multisampleGraphics = graphics;
        multisampleGraphics.SampleDesc.Count = 4;
        multisampleGraphics.RasterizerState.MultisampleEnable = TRUE;
        ComPtr<ID3D12PipelineState> multisamplePso;
        check(gpu.device->CreateGraphicsPipelineState(&multisampleGraphics,
                                                       IID_PPV_ARGS(&multisamplePso)),
              "different sample-count PSO");
        Gpu multisampleGpu(gpu.device.Get());
        const auto multisamplePixel = runRender(
            multisampleGpu, multisamplePso.Get(), graphicsRoot.Get(), false,
            DXGI_FORMAT_R8G8B8A8_UNORM, 4);
        requirePixel(multisamplePixel, {255, 0, 0, 255}, "different sample-count readback");
    }

    D3D12_ROOT_PARAMETER uavParameter{};
    uavParameter.ParameterType = D3D12_ROOT_PARAMETER_TYPE_UAV;
    uavParameter.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    uavParameter.Descriptor.ShaderRegister = 0;
    D3D12_ROOT_SIGNATURE_DESC computeRootDesc{};
    computeRootDesc.NumParameters = 1;
    computeRootDesc.pParameters = &uavParameter;
    auto computeRoot = rootSignature(gpu.device.Get(), computeRootDesc);
    const auto csA = compile(computeA, "main", "cs_5_0");
    const auto csB = compile(computeB, "main", "cs_5_0");
    D3D12_COMPUTE_PIPELINE_STATE_DESC compute{};
    compute.pRootSignature = computeRoot.Get();
    compute.CS = {csA->GetBufferPointer(), csA->GetBufferSize()};
    phase("concurrent-compute-begin");
    auto duplicateCompute = concurrentCreate(gpu.device.Get(), compute, false);
    phase("concurrent-compute-end");
    D3D12_COMPUTE_PIPELINE_STATE_DESC distinctCompute = compute;
    distinctCompute.CS = {csB->GetBufferPointer(), csB->GetBufferSize()};
    ComPtr<ID3D12PipelineState> distinctComputePso;
    check(gpu.device->CreateComputePipelineState(&distinctCompute,
                                                  IID_PPV_ARGS(&distinctComputePso)),
          "different compute shader PSO");

    Gpu computeGpuA(gpu.device.Get());
    phase("compute-duplicate-0-begin");
    const auto computeValueA = runCompute(computeGpuA, duplicateCompute[0].Get(), computeRoot.Get());
    if (computeValueA != 0x13579bdf) fail("compute duplicate #1 produced wrong GPU value");
    phase("compute-duplicate-0-end");
    Gpu computeGpuB(gpu.device.Get());
    phase("compute-duplicate-1-begin");
    const auto computeValueB = runCompute(computeGpuB, duplicateCompute[1].Get(), computeRoot.Get());
    if (computeValueB != 0x13579bdf) fail("compute duplicate #2 produced wrong GPU value");
    phase("compute-duplicate-1-end");
    Gpu computeGpuDistinct(gpu.device.Get());
    phase("compute-distinct-begin");
    const auto distinctValue = runCompute(computeGpuDistinct, distinctComputePso.Get(),
                                          computeRoot.Get());
    if (distinctValue != 0x2468ace0) fail("distinct compute PSO produced wrong GPU value");
    phase("compute-distinct-end");

#ifdef YAAGL_SMOKE_RT_DXIL_HEADER
    ComPtr<ID3D12Device5> device5;
    check(gpu.device.As(&device5), "ID3D12Device5");
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 options5{};
    check(gpu.device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &options5,
                                           sizeof(options5)),
          "D3D12_OPTIONS5");
    if (options5.RaytracingTier == D3D12_RAYTRACING_TIER_NOT_SUPPORTED) {
        fail("candidate reports no D3D12 ray tracing support");
    }
    auto rtRoot = rootSignature(gpu.device.Get(), computeRootDesc);
    D3D12_EXPORT_DESC exportDesc{L"RayGen", nullptr, D3D12_EXPORT_FLAG_NONE};
    D3D12_DXIL_LIBRARY_DESC library{};
    library.DXILLibrary = {yaaglSmokeRtDxil, yaaglSmokeRtDxilSize};
    library.NumExports = 1;
    library.pExports = &exportDesc;
    D3D12_GLOBAL_ROOT_SIGNATURE globalRoot{rtRoot.Get()};
    D3D12_RAYTRACING_SHADER_CONFIG shaderConfig{4, 8};
    D3D12_RAYTRACING_PIPELINE_CONFIG pipelineConfig{1};
    std::array<D3D12_STATE_SUBOBJECT, 4> subobjects{};
    subobjects[0] = {D3D12_STATE_SUBOBJECT_TYPE_DXIL_LIBRARY, &library};
    subobjects[1] = {D3D12_STATE_SUBOBJECT_TYPE_GLOBAL_ROOT_SIGNATURE, &globalRoot};
    subobjects[2] = {D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_SHADER_CONFIG, &shaderConfig};
    subobjects[3] = {D3D12_STATE_SUBOBJECT_TYPE_RAYTRACING_PIPELINE_CONFIG, &pipelineConfig};
    D3D12_STATE_OBJECT_DESC rtDesc{D3D12_STATE_OBJECT_TYPE_RAYTRACING_PIPELINE,
                                   static_cast<UINT>(subobjects.size()), subobjects.data()};
    phase("concurrent-rt-begin");
    auto duplicateRt = concurrentCreateRt(device5.Get(), rtDesc);
    phase("concurrent-rt-end");
    D3D12_RAYTRACING_PIPELINE_CONFIG distinctPipelineConfig{2};
    subobjects[3].pDesc = &distinctPipelineConfig;
    ComPtr<ID3D12StateObject> distinctRt;
    check(device5->CreateStateObject(&rtDesc, IID_PPV_ARGS(&distinctRt)),
          "different RT recursion-depth state object");
    Gpu rtGpuA(gpu.device.Get());
    phase("rt-duplicate-0-dispatch-begin");
    const auto rtValueA = runRayTracing(rtGpuA, rtRoot.Get(), duplicateRt[0].Get());
    phase("rt-duplicate-0-dispatch-end");
    Gpu rtGpuB(gpu.device.Get());
    phase("rt-duplicate-1-dispatch-begin");
    const auto rtValueB = runRayTracing(rtGpuB, rtRoot.Get(), duplicateRt[1].Get());
    phase("rt-duplicate-1-dispatch-end");
    Gpu rtGpuDistinct(gpu.device.Get());
    phase("rt-distinct-dispatch-begin");
    const auto rtValueDistinct = runRayTracing(rtGpuDistinct, rtRoot.Get(), distinctRt.Get());
    phase("rt-distinct-dispatch-end");
    if (rtValueA != 0xdec0adde || rtValueB != 0xdec0adde ||
        rtValueDistinct != 0xdec0adde) {
        fail("ray tracing GPU readback mismatch");
    }
#endif

    std::printf("{\"schemaVersion\":1,\"graphicsDistinctD3D12Objects\":true,"
                "\"computeDistinctD3D12Objects\":true,"
                "\"msaa4xFeatureSupported\":%s,"
                "\"directPixels\":[[%u,%u,%u,%u],[%u,%u,%u,%u]],"
                "\"indirectPixels\":[[%u,%u,%u,%u],[%u,%u,%u,%u]],"
                "\"greenUnblendedPixel\":[%u,%u,%u,%u],"
                "\"greenBlendedPixel\":[%u,%u,%u,%u],"
                "\"logicOpFeatureSupported\":true,"
                "\"logicOpAllCreated\":true,"
                "\"logicOpDistinctD3D12Objects\":true,"
                "\"logicOpPixels\":{\"baseline\":[%u,%u,%u,%u],"
                "\"copy\":[%u,%u,%u,%u],\"invert\":[%u,%u,%u,%u],"
                "\"noop\":[%u,%u,%u,%u]},\"computeValues\":[%u,%u,%u],"
#ifdef YAAGL_SMOKE_RT_DXIL_HEADER
                "\"rt\":{\"supported\":true,\"distinctD3D12Objects\":true,"
                "\"readback\":[%u,%u,%u]}}\n",
#else
                "\"rt\":{\"supported\":false}}\n",
#endif
                msaa4xSupported ? "true" : "false",
                directPixel0[0], directPixel0[1], directPixel0[2], directPixel0[3],
                directPixel1[0], directPixel1[1], directPixel1[2], directPixel1[3],
                indirectPixel0[0], indirectPixel0[1], indirectPixel0[2], indirectPixel0[3],
                indirectPixel1[0], indirectPixel1[1], indirectPixel1[2], indirectPixel1[3],
                greenUnblendedPixel[0], greenUnblendedPixel[1],
                greenUnblendedPixel[2], greenUnblendedPixel[3],
                greenBlendedPixel[0], greenBlendedPixel[1],
                greenBlendedPixel[2], greenBlendedPixel[3],
                logicBaselinePixel[0], logicBaselinePixel[1],
                logicBaselinePixel[2], logicBaselinePixel[3],
                logicCopyPixel[0], logicCopyPixel[1],
                logicCopyPixel[2], logicCopyPixel[3],
                logicInvertPixel[0], logicInvertPixel[1],
                logicInvertPixel[2], logicInvertPixel[3],
                logicNoopPixel[0], logicNoopPixel[1],
                logicNoopPixel[2], logicNoopPixel[3],
                computeValueA, computeValueB, distinctValue
#ifdef YAAGL_SMOKE_RT_DXIL_HEADER
                , rtValueA, rtValueB, rtValueDistinct
#endif
                );
    return 0;
}
