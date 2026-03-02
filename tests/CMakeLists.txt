include(FetchContent)
FetchContent_Declare(
    googletest
    URL https://github.com/google/googletest/releases/download/v1.15.2/googletest-1.15.2.tar.gz
    URL_HASH SHA256=7b42b4d6ed48810c5362c265a17faebe90dc2373c885e5216439d37927f02926
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

add_executable(olr_tests
    test_pipeline.cpp
)

target_compile_definitions(olr_tests PRIVATE
    OLR_BINARY_PATH="$<TARGET_FILE:OpenLogReplicator>"
    OLR_TEST_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}"
)

target_link_libraries(olr_tests PRIVATE GTest::gtest_main)
add_dependencies(olr_tests OpenLogReplicator)

include(GoogleTest)
gtest_discover_tests(olr_tests DISCOVERY_MODE PRE_TEST)
