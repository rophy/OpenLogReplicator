/* Full pipeline I/O tests for OpenLogReplicator
   Runs OLR binary in batch mode with redo log fixtures and compares JSON output against golden files. */

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

namespace fs = std::filesystem;

namespace {
    const std::string OLR_BIN = OLR_BINARY_PATH;
    const std::string TEST_DATA = OLR_TEST_DATA_DIR;

    struct OlrResult {
        int exitCode;
        std::string output;
    };

    // Run the OLR binary with a given config file. Returns exit code and captured stderr+stdout.
    OlrResult runOLR(const std::string& configPath) {
        // -r: allow running as root (needed in some CI containers)
        // -f: config file path
        std::string cmd = OLR_BIN + " -r -f " + configPath + " 2>&1";

        std::string output;
        std::array<char, 4096> buf{};
        FILE* pipe = popen(cmd.c_str(), "r");
        if (!pipe)
            return {-1, "popen failed"};

        while (fgets(buf.data(), buf.size(), pipe) != nullptr)
            output += buf.data();

        int status = pclose(pipe);
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        return {exitCode, output};
    }

    // Read file as vector of non-empty lines.
    std::vector<std::string> readLines(const std::string& path) {
        std::vector<std::string> lines;
        std::ifstream f(path);
        std::string line;
        while (std::getline(f, line)) {
            if (!line.empty())
                lines.push_back(line);
        }
        return lines;
    }

    // Write string to file.
    void writeFile(const std::string& path, const std::string& content) {
        std::ofstream f(path);
        f << content;
    }

    // Compare actual output file against expected golden file, line by line.
    // Returns empty string on match, or a description of the first difference.
    std::string compareGoldenFile(const std::string& actualPath, const std::string& expectedPath) {
        auto actual = readLines(actualPath);
        auto expected = readLines(expectedPath);

        size_t maxLines = std::max(actual.size(), expected.size());
        for (size_t i = 0; i < maxLines; ++i) {
            if (i >= actual.size())
                return "actual has fewer lines than expected (actual: " + std::to_string(actual.size()) +
                       ", expected: " + std::to_string(expected.size()) + ")";
            if (i >= expected.size())
                return "actual has more lines than expected (actual: " + std::to_string(actual.size()) +
                       ", expected: " + std::to_string(expected.size()) + ")";
            if (actual[i] != expected[i])
                return "line " + std::to_string(i + 1) + " differs:\n  actual:   " + actual[i] + "\n  expected: " + expected[i];
        }
        return {};
    }
}

class PipelineTest : public ::testing::Test {
protected:
    fs::path tmpDir;

    void SetUp() override {
        // Create a unique temp directory for this test
        tmpDir = fs::temp_directory_path() / ("olr_test_" + std::to_string(getpid()) + "_" + std::to_string(rand()));
        fs::create_directories(tmpDir);
    }

    void TearDown() override {
        if (fs::exists(tmpDir))
            fs::remove_all(tmpDir);
    }

    // Check if a test fixture set exists. Skip the test if not.
    void requireFixture(const std::string& name) {
        fs::path redoDir = fs::path(TEST_DATA) / "redo" / name;
        fs::path expectedDir = fs::path(TEST_DATA) / "expected" / name;
        if (!fs::exists(redoDir) || !fs::exists(expectedDir))
            GTEST_SKIP() << "Fixture '" << name << "' not found. "
                         << "See tests/data/README.md for capture instructions.";
    }

    // Build a batch-mode config JSON for a given fixture.
    // Discovers all .arc files in the fixture redo directory.
    std::string buildBatchConfig(const std::string& fixtureName, const std::string& outputPath) {
        fs::path redoDir = fs::path(TEST_DATA) / "redo" / fixtureName;
        fs::path schemaDir = fs::path(TEST_DATA) / "schema" / fixtureName;

        // Collect all redo log files
        std::vector<std::string> redoFiles;
        for (const auto& entry : fs::directory_iterator(redoDir)) {
            if (entry.is_regular_file())
                redoFiles.push_back(entry.path().string());
        }
        std::sort(redoFiles.begin(), redoFiles.end());

        // Build redo-log JSON array
        std::string redoLogArray = "[";
        for (size_t i = 0; i < redoFiles.size(); ++i) {
            if (i > 0) redoLogArray += ", ";
            redoLogArray += "\"" + redoFiles[i] + "\"";
        }
        redoLogArray += "]";

        // State path for checkpoint/schema
        std::string statePath = schemaDir.string();

        std::string config = R"({
  "version": "1.8.7",
  "log-level": 3,
  "source": [
    {
      "alias": "S1",
      "name": "TEST",
      "reader": {
        "type": "batch",
        "redo-log": )" + redoLogArray + R"(,
        "log-archive-format": ""
      },
      "format": {
        "type": "json"
      },
      "flags": 2,
      "memory": {
        "min-mb": 32,
        "max-mb": 256
      },
      "state": {
        "type": "disk",
        "path": ")" + statePath + R"("
      }
    }
  ],
  "target": [
    {
      "alias": "T1",
      "source": "S1",
      "writer": {
        "type": "file",
        "output": ")" + outputPath + R"(",
        "new-line": 1,
        "append": 0
      }
    }
  ]
})";
        return config;
    }
};

TEST_F(PipelineTest, BatchSingleTransaction) {
    requireFixture("single-transaction");

    std::string outputPath = (tmpDir / "output.json").string();
    std::string config = buildBatchConfig("single-transaction", outputPath);
    std::string configPath = (tmpDir / "config.json").string();
    writeFile(configPath, config);

    auto result = runOLR(configPath);
    ASSERT_EQ(result.exitCode, 0) << "OLR failed with output:\n" << result.output;
    ASSERT_TRUE(fs::exists(outputPath)) << "Output file not created. OLR output:\n" << result.output;

    std::string expectedPath = (fs::path(TEST_DATA) / "expected" / "single-transaction" / "output.json").string();
    std::string diff = compareGoldenFile(outputPath, expectedPath);
    EXPECT_TRUE(diff.empty()) << "Golden file mismatch:\n" << diff;
}

TEST_F(PipelineTest, BatchMultipleOperations) {
    requireFixture("multiple-operations");

    std::string outputPath = (tmpDir / "output.json").string();
    std::string config = buildBatchConfig("multiple-operations", outputPath);
    std::string configPath = (tmpDir / "config.json").string();
    writeFile(configPath, config);

    auto result = runOLR(configPath);
    ASSERT_EQ(result.exitCode, 0) << "OLR failed with output:\n" << result.output;
    ASSERT_TRUE(fs::exists(outputPath)) << "Output file not created. OLR output:\n" << result.output;

    std::string expectedPath = (fs::path(TEST_DATA) / "expected" / "multiple-operations" / "output.json").string();
    std::string diff = compareGoldenFile(outputPath, expectedPath);
    EXPECT_TRUE(diff.empty()) << "Golden file mismatch:\n" << diff;
}

TEST_F(PipelineTest, BatchRacMultiThread) {
    requireFixture("rac-multi-thread");

    std::string outputPath = (tmpDir / "output.json").string();
    std::string config = buildBatchConfig("rac-multi-thread", outputPath);
    std::string configPath = (tmpDir / "config.json").string();
    writeFile(configPath, config);

    auto result = runOLR(configPath);
    ASSERT_EQ(result.exitCode, 0) << "OLR failed with output:\n" << result.output;
    ASSERT_TRUE(fs::exists(outputPath)) << "Output file not created. OLR output:\n" << result.output;

    std::string expectedPath = (fs::path(TEST_DATA) / "expected" / "rac-multi-thread" / "output.json").string();
    std::string diff = compareGoldenFile(outputPath, expectedPath);
    EXPECT_TRUE(diff.empty()) << "Golden file mismatch:\n" << diff;
}

// --- Auto-discovered parameterized fixtures ---
// Discovers fixture names from tests/data/expected/*/ directories that also have
// corresponding redo/ directories. This allows generate.sh to create new fixtures
// that are automatically picked up by ctest without modifying C++ code.

namespace {
    std::vector<std::string> discoverFixtures() {
        std::vector<std::string> fixtures;
        fs::path expectedDir = fs::path(TEST_DATA) / "expected";
        fs::path redoDir = fs::path(TEST_DATA) / "redo";

        if (!fs::exists(expectedDir) || !fs::exists(redoDir))
            return fixtures;

        for (const auto& entry : fs::directory_iterator(expectedDir)) {
            if (!entry.is_directory())
                continue;
            std::string name = entry.path().filename().string();
            // Skip fixtures that have dedicated named tests above
            if (name == "single-transaction" || name == "multiple-operations" || name == "rac-multi-thread")
                continue;
            // Only include if both expected output and redo logs exist
            if (fs::exists(entry.path() / "output.json") && fs::exists(redoDir / name))
                fixtures.push_back(name);
        }
        std::sort(fixtures.begin(), fixtures.end());
        return fixtures;
    }
}

class PipelineParamTest : public PipelineTest,
                          public ::testing::WithParamInterface<std::string> {};

TEST_P(PipelineParamTest, BatchFixture) {
    std::string fixtureName = GetParam();
    requireFixture(fixtureName);

    std::string outputPath = (tmpDir / "output.json").string();
    std::string config = buildBatchConfig(fixtureName, outputPath);
    std::string configPath = (tmpDir / "config.json").string();
    writeFile(configPath, config);

    auto result = runOLR(configPath);
    ASSERT_EQ(result.exitCode, 0) << "OLR failed with output:\n" << result.output;
    ASSERT_TRUE(fs::exists(outputPath)) << "Output file not created. OLR output:\n" << result.output;

    std::string expectedPath = (fs::path(TEST_DATA) / "expected" / fixtureName / "output.json").string();
    std::string diff = compareGoldenFile(outputPath, expectedPath);
    EXPECT_TRUE(diff.empty()) << "Golden file mismatch:\n" << diff;
}

INSTANTIATE_TEST_SUITE_P(
    Fixtures,
    PipelineParamTest,
    ::testing::ValuesIn(discoverFixtures()),
    [](const ::testing::TestParamInfo<std::string>& info) { return info.param; }
);
