import RiftIPC

enum CLIFileAccess {
    static func beginRead(path: String, maximumBytes: Int) throws -> DescriptorInputFile {
        try DescriptorFileAccess.beginRead(path: path, maximumBytes: maximumBytes)
    }

    static func beginCreate(path: String) throws -> DescriptorOutputFile {
        try DescriptorFileAccess.beginCreate(path: path)
    }
}
