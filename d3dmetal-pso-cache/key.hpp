#pragma once

#import <Foundation/Foundation.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace yaagl::pso {

enum class Api : std::uint32_t {
    Metal4Render,
    Render,
    Mesh,
    Compute,
};

enum class ContextKind : std::uint32_t {
    None,
    Graphics,
    Compute,
};

struct Context final {
    ContextKind kind = ContextKind::None;
    const void* owner = nullptr;
    std::uint32_t dynamicFlags = 0;
    std::uint64_t formats = 0;
};

class KeyBytes final {
public:
    static constexpr std::size_t kInlineCapacity = 1024;

    void clear() noexcept {
        size_ = 0;
        overflow_.clear();
    }

    void append(const void* data, std::size_t size);

    [[nodiscard]] const std::uint8_t* data() const noexcept {
        return overflow_.empty() ? inline_.data() : overflow_.data();
    }
    [[nodiscard]] std::size_t size() const noexcept { return size_; }
    [[nodiscard]] const std::uint8_t* begin() const noexcept { return data(); }
    [[nodiscard]] const std::uint8_t* end() const noexcept { return data() + size_; }

private:
    std::array<std::uint8_t, kInlineCapacity> inline_;
    std::vector<std::uint8_t> overflow_;
    std::size_t size_ = 0;
};

class Key final {
public:
    Key() noexcept = default;
    Key(const Key&) = delete;
    Key& operator=(const Key&) = delete;
    ~Key();

    void reset() noexcept;

    KeyBytes bytes;
    NSArray* resources = nil;
};

// Returns false when the intercepted helper is not from the recognized D3DMetal
// context, or when complete canonical shader provenance cannot be established.
// On false, output is reset and the caller must invoke the original helper.
[[nodiscard]] bool makeKey(
    Api api,
    const void* device,
    id descriptor,
    std::uint64_t options,
    bool reflectionRequested,
    const Context& context,
    Key& output);

} // namespace yaagl::pso
