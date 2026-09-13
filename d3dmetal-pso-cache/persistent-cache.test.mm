#ifndef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
#error "persistent cache tests require YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS"
#endif

#include "persistent-cache.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

#define CHECK(condition) do { \
    if (!(condition)) { \
        std::cerr << __FILE__ << ':' << __LINE__ << ": check failed: " #condition << '\n'; \
        std::abort(); \
    } \
} while (false)

namespace {

class TemporaryDirectory final {
public:
    TemporaryDirectory() {
        char pattern[] = "/tmp/yaagl-persistent-cache.XXXXXX";
        const char* created = mkdtemp(pattern);
        CHECK(created != nullptr);
        path = created;
    }
    ~TemporaryDirectory() {
        const std::string command = "/bin/rm -rf '" + path + "'";
        CHECK(std::system(command.c_str()) == 0);
    }
    std::string path;
};

void makeDirectory(const std::string& path) {
    CHECK(mkdir(path.c_str(), 0700) == 0);
}

void makeFile(const std::string& path, off_t size) {
    const int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    CHECK(fd >= 0);
    CHECK(ftruncate(fd, size) == 0);
    CHECK(close(fd) == 0);
}

std::string makeCacheTree(const TemporaryDirectory& temporary, const char* gpu) {
    makeDirectory(temporary.path + "/d3dm");
    makeDirectory(temporary.path + "/d3dm/Game.exe");
    makeDirectory(temporary.path + "/d3dm/Game.exe/shaders.cache");
    const std::string directory = temporary.path + "/d3dm/Game.exe/shaders.cache/" + gpu;
    makeDirectory(directory);
    return directory;
}

void testWarmsOnlyBoundedNativeFiles() {
    TemporaryDirectory temporary;
    const std::string gpu = makeCacheTree(temporary, "MTLGPUFamilyApple10_1");
    makeFile(gpu + "/version.bin", 32);
    makeFile(gpu + "/bytecode_cache.bin", 2 * 1024 * 1024);
    makeFile(gpu + "/rootsignature_cache.bin", 2 * 1024 * 1024);
    makeFile(gpu + "/stage_cache.bin", 512LL * 1024 * 1024);
    makeFile(gpu + "/pipeline_cache.bin", 2 * 1024 * 1024);
    makeFile(gpu + "/not-a-native-cache.bin", 2 * 1024 * 1024);
    makeDirectory(gpu + "/nested");
    makeFile(gpu + "/nested/stage_cache.bin", 2 * 1024 * 1024);

    const auto result = yaagl::pso::warmPersistentCachesAt(temporary.path.c_str(), "Game.exe");
    CHECK(result.directoriesVisited == 1);
    CHECK(result.filesAdvised == 5);
    CHECK(result.bytesAdvised == 4ULL * 1024 * 1024 + 32);

    struct stat status {};
    CHECK(stat((gpu + "/stage_cache.bin").c_str(), &status) == 0);
    CHECK(status.st_size == 512LL * 1024 * 1024);
}

void testRejectsSymlinksAndUnrelatedDirectories() {
    TemporaryDirectory temporary;
    const std::string gpu = makeCacheTree(temporary, "MTLGPUFamilyApple10_0");
    makeFile(gpu + "/version.bin", 16);
    makeFile(gpu + "/bytecode_cache.bin", 4096);
    makeFile(gpu + "/rootsignature_cache.bin", 4096);
    makeFile(gpu + "/stage_cache.bin", 4096);
    makeFile(temporary.path + "/outside.bin", 4096);
    CHECK(symlink((temporary.path + "/outside.bin").c_str(),
        (gpu + "/pipeline_cache.bin").c_str()) == 0);
    makeDirectory(temporary.path + "/d3dm/Game.exe/shaders.cache/unrelated");
    makeFile(temporary.path + "/d3dm/Game.exe/shaders.cache/unrelated/stage_cache.bin", 4096);

    const auto result = yaagl::pso::warmPersistentCachesAt(temporary.path.c_str(), "Game.exe");
    CHECK(result.directoriesVisited == 1);
    CHECK(result.filesAdvised == 4);
    CHECK(result.bytesAdvised == 16 + 3 * 4096);

    CHECK(yaagl::pso::warmPersistentCachesAt(temporary.path.c_str(), "../Game.exe").filesAdvised == 0);
    const std::string rootLink = temporary.path + ".link";
    CHECK(symlink(temporary.path.c_str(), rootLink.c_str()) == 0);
    CHECK(yaagl::pso::warmPersistentCachesAt(rootLink.c_str(), "Game.exe").filesAdvised == 0);
    CHECK(unlink(rootLink.c_str()) == 0);
}

void testFdopendirFailureClosesEnumerationDescriptor() {
    TemporaryDirectory temporary;
    static_cast<void>(makeCacheTree(temporary, "MTLGPUFamilyApple10_1"));

    yaagl::pso::setFdopendirFailureForTest(true);
    const auto result = yaagl::pso::warmPersistentCachesAt(temporary.path.c_str(), "Game.exe");
    const int enumerationFd = yaagl::pso::lastFdopendirFdForTest();
    yaagl::pso::setFdopendirFailureForTest(false);

    CHECK(result.directoriesVisited == 0);
    CHECK(enumerationFd >= 0);
    errno = 0;
    CHECK(fcntl(enumerationFd, F_GETFD) == -1);
    CHECK(errno == EBADF);
}

void testEnvironmentOptInAndFailOpenPaths() {
    TemporaryDirectory temporary;
    const std::string gpu = makeCacheTree(temporary, "MTLGPUFamilyApple10_1");
    makeFile(gpu + "/version.bin", 8);
    makeFile(gpu + "/stage_cache.bin", 4096);

    unsetenv("YAAGL_D3DMETAL_CACHE_WARMUP");
    setenv("YAAGL_D3DMETAL_CACHE_ROOT", temporary.path.c_str(), 1);
    setenv("YAAGL_D3DMETAL_CACHE_EXECUTABLE", "Game.exe", 1);
    CHECK(yaagl::pso::warmPersistentCachesFromEnvironment().filesAdvised == 0);
    setenv("YAAGL_D3DMETAL_CACHE_WARMUP", "true", 1);
    CHECK(yaagl::pso::warmPersistentCachesFromEnvironment().filesAdvised == 0);
    setenv("YAAGL_D3DMETAL_CACHE_WARMUP", "1", 1);
    CHECK(yaagl::pso::warmPersistentCachesFromEnvironment().filesAdvised == 2);
    unsetenv("YAAGL_D3DMETAL_CACHE_EXECUTABLE");
    setprogname("Game.exe");
    CHECK(yaagl::pso::warmPersistentCachesFromEnvironment().filesAdvised == 2);
    setenv("YAAGL_D3DMETAL_CACHE_EXECUTABLE", "Missing.exe", 1);
    CHECK(yaagl::pso::warmPersistentCachesFromEnvironment().filesAdvised == 0);

    unsetenv("YAAGL_D3DMETAL_CACHE_WARMUP");
    unsetenv("YAAGL_D3DMETAL_CACHE_ROOT");
    unsetenv("YAAGL_D3DMETAL_CACHE_EXECUTABLE");
}

} // namespace

int main() {
    testWarmsOnlyBoundedNativeFiles();
    testRejectsSymlinksAndUnrelatedDirectories();
    testFdopendirFailureClosesEnumerationDescriptor();
    testEnvironmentOptInAndFailOpenPaths();
    std::cout << "persistent cache warmup tests passed\n";
}
