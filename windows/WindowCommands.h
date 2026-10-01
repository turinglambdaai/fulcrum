#pragma once

#include <string>

namespace fulcrum {

// Native window management for the `win.*` engine actions. Targets the
// foreground window; unlike macOS this needs no special permission.
bool RunWindowCommand(std::string const& id);

} // namespace fulcrum
