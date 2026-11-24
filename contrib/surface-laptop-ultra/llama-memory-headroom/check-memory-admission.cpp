#include "server-memory-admission.h"

#include <cassert>
#include <sstream>

int main() {
    std::istringstream missing("MemFree: 90000000 kB\nSwapFree: 90000000 kB\n");
    assert(server_check_model_memory("", missing).empty());
    assert(missing.tellg() == 0);
    assert(server_check_model_memory("0", missing).find("positive integer") != std::string::npos);
    assert(server_check_model_memory("-1", missing).find("positive integer") != std::string::npos);
    assert(server_check_model_memory("20MB", missing).find("positive integer") != std::string::npos);
    assert(server_check_model_memory("18446744073709551616", missing).find("positive integer") != std::string::npos);
    assert(server_check_model_memory("1", missing).find("cannot read MemAvailable") != std::string::npos);

    std::istringstream malformed("MemAvailable: 30000000 MB\n");
    assert(server_check_model_memory("1", malformed).find("cannot read MemAvailable") != std::string::npos);

    std::istringstream low("MemTotal: 60388028 kB\nMemAvailable: 30719999 kB\nSwapFree: 60387324 kB\n");
    assert(server_check_model_memory("30000", low) == "model load deferred: 29999 MiB available, requires 30000 MiB");

    std::istringstream exact("MemAvailable: 30720000 kB\n");
    assert(server_check_model_memory("30000", exact).empty());

    std::istringstream high("MemAvailable: 40760860 kB\n");
    assert(server_check_model_memory("30000", high).empty());
}
