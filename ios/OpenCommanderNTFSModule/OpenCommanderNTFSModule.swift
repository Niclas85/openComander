// SPDX-License-Identifier: MIT

import ExtensionFoundation
import FSKit

@main
struct OpenCommanderNTFSModule: UnaryFileSystemExtension {
    let fileSystem = OpenCommanderNTFSFileSystem()
}
