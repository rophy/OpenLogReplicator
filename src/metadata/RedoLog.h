/* Struct to store redo log group and path.
   Copyright (C) 2018-2026 Adam Leszczynski (aleszczynski@bersler.com)

This file is part of OpenLogReplicator.

OpenLogReplicator is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License as published
by the Free Software Foundation; either version 3, or (at your option)
any later version.

OpenLogReplicator is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
Public License for more details.

You should have received a copy of the GNU General Public License
along with OpenLogReplicator; see the file LICENSE;  If not see
<http://www.gnu.org/licenses/>.  */

#ifndef REDO_LOG_H_
#define REDO_LOG_H_

#include <string>

#include "../common/types/Types.h"

namespace OpenLogReplicator {
    class RedoLog final {
    public:
        uint16_t thread;
        int group;
        std::string path;

        RedoLog(uint16_t newThread, int newGroup, std::string newPath):
            thread(newThread),
            group(newGroup),
            path(std::move(newPath)) {}

        bool operator<(const RedoLog& other) const {
            if (thread < other.thread)
                return true;
            if (other.thread < thread)
                return false;
            if (group < other.group)
                return true;
            if (other.group < group)
                return false;
            if (path < other.path)
                return true;
            return false;
        }
    };
}

#endif
