#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iterator>

namespace {
using HRESULT = std::int32_t;
using ULONG = std::uint32_t;
using UINT32 = std::uint32_t;
using BOOL = std::int32_t;

struct Guid {
    std::uint32_t data1;
    std::uint16_t data2;
    std::uint16_t data3;
    std::uint8_t data4[8];
};

constexpr Guid kClsidCompiler{0x73e22d93, 0xe6ce, 0x47f3,
                              {0xb5, 0xbf, 0xf0, 0x66, 0x4f, 0x39, 0xc1, 0xb0}};
constexpr Guid kIidCompiler3{0x228b4687, 0x5a6a, 0x4730,
                             {0x90, 0x0c, 0x97, 0x02, 0xb2, 0x20, 0x3f, 0x54}};
constexpr Guid kIidResult{0x58346cda, 0xdde7, 0x4497,
                          {0x94, 0x61, 0x6f, 0x87, 0xaf, 0x5e, 0x06, 0x59}};

struct Unknown {
    virtual HRESULT QueryInterface(const Guid&, void**) = 0;
    virtual ULONG AddRef() = 0;
    virtual ULONG Release() = 0;
};
struct Blob : Unknown {
    virtual void* GetBufferPointer() = 0;
    virtual std::size_t GetBufferSize() = 0;
};
struct BlobEncoding : Blob {
    virtual HRESULT GetEncoding(BOOL*, UINT32*) = 0;
};
struct Result : Unknown {
    virtual HRESULT GetStatus(HRESULT*) = 0;
    virtual HRESULT GetResult(Blob**) = 0;
    virtual HRESULT GetErrorBuffer(BlobEncoding**) = 0;
};
struct Buffer {
    const void* pointer;
    std::size_t size;
    UINT32 encoding;
};
struct Compiler3 : Unknown {
    virtual HRESULT Compile(const Buffer*, const wchar_t* const*, UINT32, Unknown*,
                            const Guid&, void**) = 0;
    virtual HRESULT Disassemble(const Buffer*, const Guid&, void**) = 0;
};
using CreateInstance = HRESULT (*)(const Guid&, const Guid&, void**);

constexpr char kRayLibrary[] =
    "RWByteAddressBuffer outputBuffer:register(u0);"
    "[shader(\"raygeneration\")] void RayGen(){outputBuffer.Store(0,0xdec0adde);}";

[[noreturn]] void fail(const char* message) {
    std::fprintf(stderr, "d3dmetal-pso-cache-smoke-dxc: %s\n", message);
    std::exit(1);
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 3) fail("usage: smoke-dxc <libdxcompiler.dylib> <output.dxil>");
    void* module = dlopen(argv[1], RTLD_LOCAL | RTLD_NOW);
    if (!module) fail(dlerror());
    const auto create = reinterpret_cast<CreateInstance>(dlsym(module, "DxcCreateInstance"));
    if (!create) fail("DxcCreateInstance export missing");
    Compiler3* compiler = nullptr;
    if (create(kClsidCompiler, kIidCompiler3, reinterpret_cast<void**>(&compiler)) < 0 ||
        !compiler) {
        fail("IDxcCompiler3 unavailable");
    }
    const Buffer source{kRayLibrary, std::strlen(kRayLibrary), 65001};
    const wchar_t* arguments[] = {L"-T", L"lib_6_3", L"-HV", L"2021", L"-Ges",
                                  L"-O3", L"-Qstrip_debug", L"-Qstrip_reflect"};
    Result* result = nullptr;
    const HRESULT call = compiler->Compile(&source, arguments,
                                            static_cast<UINT32>(std::size(arguments)),
                                            nullptr, kIidResult,
                                            reinterpret_cast<void**>(&result));
    compiler->Release();
    if (call < 0 || !result) fail("IDxcCompiler3::Compile failed");
    HRESULT status = -1;
    if (result->GetStatus(&status) < 0 || status < 0) {
        BlobEncoding* errors = nullptr;
        if (result->GetErrorBuffer(&errors) >= 0 && errors) {
            std::fwrite(errors->GetBufferPointer(), 1, errors->GetBufferSize(), stderr);
            errors->Release();
        }
        fail("ray library compilation failed");
    }
    Blob* object = nullptr;
    if (result->GetResult(&object) < 0 || !object || object->GetBufferSize() == 0) {
        fail("DXC returned no ray library object");
    }
    std::ofstream output(argv[2], std::ios::binary | std::ios::trunc);
    output.write(static_cast<const char*>(object->GetBufferPointer()),
                 static_cast<std::streamsize>(object->GetBufferSize()));
    if (!output) fail("writing DXIL output failed");
    object->Release();
    result->Release();
    dlclose(module);
    return 0;
}
